#!/usr/bin/env ruby

require 'optparse'
require 'fileutils'
require 'pathname'
require 'time'
require 'forwardable'

class Build
  include Comparable
  extend Forwardable

  def self.from_path(path)
    path = Pathname.new path

    case path.basename.to_s
    when /^(\d+)$/
      NumberedBuildLink.new path
    when /^\d{4}-\d{2}-\d{2}_\d{2}-\d{2}-\d{2}$/
      DatedBuild.new path
    else
      nil
    end
  end

  attr_reader :path

  def_delegators(
    :path,
    :symlink?,
    :directory?,
    :exist?,
    :unlink,
    :rmtree,
    :readlink
  )

  def initialize(path)
    @path = path
  end

  def to_i
    number
  end
end

class NumberedBuildLink < Build
  attr_accessor :number
  def_delegator :date_build, :time

  def initialize(path)
    super
    @number = Integer(path.basename.to_s)
  end

  def <=>(other)
    number <=> other.number
  end

  def date_build
    @date_build ||= DatedBuild.new path.readlink.relative? ? path.dirname + path.readlink : path.readlink
  end

  def to_s
    path.symlink? ? "#{path} -> #{readlink}" : path.to_s
  end
end

class DatedBuild < Build
  attr_accessor :time

  def initialize(path)
    super
    m = path.basename.to_s.match(/^(\d{4}-\d{2}-\d{2})_(\d{2})-(\d{2})-(\d{2})$/)
    @time = Time.parse("#{m[1]} #{m[2]}:#{m[3]}:#{m[4]}") if m
  end

  def <=>(other)
    time <=> other.time
  end

  def number
    @number ||= fail 'fetch from xml'
  end

  def date_build
    self
  end

  def to_s
    path.to_s
  end
end

class Solution
  attr_reader :message

  def initialize(message, &block)
    @message = message
    @block = block
  end

  def solve
    @block.call
  end

  def to_s
    message
  end
end

# Comment
class Job
  attr_reader :path, :numbers, :dates, :problems, :solutions

  def initialize(path)
    @path = Pathname.new path
    @problems = []
    @solutions = []
  end

  def builds_path
    path + 'builds'
  end

  def scan_builds
    @dates = []
    @numbers = []

    builds_path.children.each do |child|
      build = Build.from_path(child)

      case build
      when NumberedBuildLink
        @numbers << build
      when DatedBuild
        @dates << build
      end
    end

    @numbers.sort!
    @dates.sort!
  end

  def problem?
    tests = methods.select { |m| m.to_s.start_with? 'test_'  }
    tests.each do |m|
      send m
    end

    problems.length > 0
  end

  def next_build_number
    @next_build_number ||= Integer((path + 'nextBuildNumber').read)
  end

  def problem(type, message)
    @problems << "#{type}: #{message}"
  end

  def solution(message, &block)
    @solutions << Solution.new(message, &block)
  end

  def dumping_ground
    @dumping_group ||= (path + 'outOfOrderBuilds').tap do |p|
      p.mkdir unless p.exist?
    end
  end

  def archive(path)
    path = path.path if path.respond_to? :path
    path.rename(dumping_ground + path.basename)
  end

  def test_is_a_job_directory
    unless (path + 'config.xml').exist?
      problem :NOJOB, "#{path} is not a job directory; 'config.xml' is missing."
    end
  end

  def test_last_links_should_be_links
    links = %w(lastFailedBuild lastStableBuild lastSuccessfulBuild lastUnstableBuild lastUnsuccessfulBuild)

    links.map { |l| builds_path + l }.select { |p| !p.symlink? && p.exist? }.each do |path|
      problem :NOTLINK, "#{path} should be a symlink but isn't."

      solution("Relink #{path}") do
        path.rmtree if path.directory?
        path.unlink if path.exist?
        File.symlink '-1', path.to_s
      end
    end
  end

  def test_numbers_are_not_files
    numbers.reject(&:symlink?).each do |number|
      problem :NOTLINK, "The number link #{number} is not a symlink!"
      solution("Archive #{number}") { archive number }
    end
  end

  def test_broken_number_link
    numbers.reject(&:exist?).each do |number|
      problem :BROKEN, "The number link #{number} is broken."
      solution("Unlink #{number}") { number.unlink }
    end
  end

  def test_dates_for_numbers_are_in_order
    valid_numbers = numbers.select(&:symlink?).select(&:exist?)

    valid_numbers.each_with_index do |number, i|
      if number.time > valid_numbers.map(&:time)[i..-1].min
        problem :ORDER, "The link #{number} is out of order."
        solution("Archive #{number}") { archive number }
      end
    end
  end

  def test_dates_without_numbers
    (dates.map(&:to_s) - numbers.select(&:symlink?).map(&:date_build).map(&:to_s)).each do |date|
      problem :NONUM, "The following date build doesn't have a matching number link: #{date}"
    end
  end

  def test_next_build_number
    # assert next_build_number == numbers.sort.last + 1
    return if dates.empty? && numbers.empty?
    given = next_build_number
    expected = numbers.last.to_i + 1
    if given < expected
      problem :NEXT, "The nextBuildNumber is set to #{given} but I expected at least #{expected}"
      solution('Reset nextBuildNumber') do
        File.open(path + 'nextBuildNumber', 'w') { |f| f.puts expected }
      end
    end
  end
end

if $PROGRAM_NAME == __FILE__
  $stdout.sync = true # unbuffered output

  mode = :seek

  OptionParser.new do |opts|
    opts.banner = 'Usage: jobber.rb [options]'

    opts.on('-s', '--solve', 'Try to automagically solve the problems') do
      mode = :destroy
    end
  end.parse!

  if ARGV.map { |p| File.directory? p }.reduce(true) { |a, e| a && e }
    print 'Scanning: '
    all_problems = {}
    all_solutions = {}
    ARGV.each do |path|
      job = Job.new path
      job.scan_builds
      # p job
      # p job.next_build_number

      if job.problem?
        all_problems[File.basename path] = job.problems
        all_solutions[File.basename path] = job.solutions unless job.solutions.empty?
        print '*'
      else
        print '.'
      end
    end
    puts

    if all_problems.length > 0
      count = 0
      puts
      puts '**** PROBLEMS ****'
      all_problems.keys.sort.each do |key|
        puts "#{key}:"
        all_problems[key].each do |problem|
          puts " * #{problem}"
          count += 1
        end
      end

      puts
      puts "Found #{count} problems."

      puts
      puts '**** SOLUTIONS ****'
      all_solutions.keys.sort.each do |key|
        unless all_solutions[key].empty?
          puts "#{key}: "
          all_solutions[key].each do |solution|
            puts " * #{solution}"
            solution.solve if :destroy == mode
          end
        end
      end
    else
      puts 'No problems!'
    end
  else
    fail "You need to give me a 'build' style directory."
  end
end
