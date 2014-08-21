#!/usr/bin/env ruby
# encoding: utf-8
# The MIT License (MIT)
#
# Copyright (c) 2014 Christian Holtje
#
# Permission is hereby granted, free of charge, to any person obtaining a copy
# of this software and associated documentation files (the "Software"), to deal
# in the Software without restriction, including without limitation the rights
# to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
# copies of the Software, and to permit persons to whom the Software is
# furnished to do so, subject to the following conditions:
#
# The above copyright notice and this permission notice shall be included in all
# copies or substantial portions of the Software.
#
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
# AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
# LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
# OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
# SOFTWARE.

require 'optparse'
require 'stringio'
require 'fileutils'
require 'pathname'
require 'time'
require 'forwardable'
require 'set'
require 'rexml/document'

class Build
  include Comparable
  extend Forwardable

  def self.from_path(path)
    path = Pathname.new path
    return nil unless path.exist? || path.symlink?

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
    :file?,
    :directory?,
    :exist?,
    :unlink,
    :rmtree,
    :readlink,
    :rename,
    :basename,
    :realpath,
    :realdirpath
  )

  def initialize(path)
    @path = path
  end

  def name
    "builds/#{basename}"
  end

  def hash
    realdirpath.hash
  end

  def eql?(other)
    realdirpath == other.realdirpath
  end

  def to_i
    number
  end

  def to_s
    name
  end

  def to_path
    path
  end
end

class NumberedBuildLink < Build
  attr_accessor :number
  def_delegator :date_build, :time

  def initialize(path)
    super
    @number = Integer(path.basename.to_s)
  end

  def date_build
    if symlink?
      @date_build ||= DatedBuild.new(path.readlink.relative? ? path.dirname + path.readlink : path.readlink)
    else
      @date_build = nil
    end
  end

  def number_path
    path
  end

  def number_build
    self
  end

  def <=>(other)
    number <=> other.number
  end

  def name
    path.symlink? ? "builds/#{basename} -> #{readlink.basename}" : "builds/#{basename}"
  end
end

class DatedBuild < Build
  attr_accessor :time

  def initialize(path)
    super
    m = path.basename.to_s.match(/^(\d{4}-\d{2}-\d{2})_(\d{2})-(\d{2})-(\d{2})$/)
    @time = Time.parse("#{m[1]} #{m[2]}:#{m[3]}:#{m[4]}") if m
  end

  def number
    @number ||= build_xml.nil? ? nil : Integer(REXML::XPath.first(build_xml, '/*/number').text)
  end

  def date_build
    self
  end

  def number_path
    @number_path ||= number ? path.dirname + number.to_s : nil
  end

  def number_build
    @number_build ||= (number && number_path.symlink?) ?  NumberedBuildLink.new(number_path) : nil
  end

  def <=>(other)
    time <=> other.time
  end

  def build_xml
    build_xml_path = path + 'build.xml'
    @build_xml ||= build_xml_path.file? ? REXML::Document.new(build_xml_path.read) : nil
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
    @has_problems = :unset
  end

  def builds_path
    path + 'builds'
  end

  def name
    path.basename.to_s
  end

  def scan_builds
    @dates = []
    @numbers = []

    return unless builds_path.directory?

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
    if @has_problems == :unset
      tests = methods.select { |m| m.to_s.start_with? 'test_'  }
      tests.each do |m|
        send m
      end

      @has_problems = problems.length > 0
    end
    @has_problems
  rescue
    $stderr.puts "Error while checking for problems in #{name}"
    raise
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
    path.rename(dumping_ground + path.basename)
  end

  def test_is_a_job_directory
    problem :NOJOB, "#{path} is not a job directory; 'config.xml' is missing." unless (path + 'config.xml').exist?
  end

  def test_last_links_should_be_links
    links = %w(
      lastFailedBuild
      lastStableBuild
      lastSuccessfulBuild
      lastUnstableBuild
      lastUnsuccessfulBuild
    ).map { |l| builds_path + l }

    links.reject(&:symlink?).select(&:exist?).each do |path|
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
      solution("Archive non-link #{number}") { archive number }
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
        solution("Archive out-of-order #{number}") do
          archive number.date_build
          archive number
        end
      end
    end
  end

  def test_dates_without_numbers
    missing_links = Set.new(dates) - Set.new(numbers.select(&:symlink?).map(&:date_build))
    missing_links.each do |date|
      if date.number_build && date.number_build.exist? && date.number_build.date_build != date
        if date.number_build.symlink?
          problem :STOLEN, "The date build #{date} had its number stolen by #{date.number_build}"
          solution("Relink #{date.number} to #{date}") do
            date.number_path.unlink if date.number_path.symlink? || date.number_path.file?
            File.symlink date.basename.to_s, date.number_path.to_s
          end
          solution("Archive newer build #{date.number_build.date_build}") { archive date.number_build.date_build }
        end
      else
        if date.number_build || !date.number_path.symlink?
          problem :NONUM, "The #{date} directory is missing the #{date.number} link."
          solution("Relink #{date.number} to #{date}") do
            File.symlink date.basename.to_s, date.number_path.to_s
          end
        elsif date.number_path
          problem :NUMBAD, "The #{date.number} file object is not a symlink."
          solution("Archive #{date.number} and relink #{date.number} to #{date}") do
            archive date.number_path
            File.symlink date.basename.to_s, date.number_path.to_s
          end
        else
          problem :BADDATE, "The #{date} directory isn't well formed."
          solution("Archive badly formed #{date}") { archive date }
        end
      end
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

class Application
  attr_reader :args, :verbosity, :mode

  def initialize(args)
    @args = args
    @mode = :seek
    @verbosity = :all
    @job_paths = []
  end

  def parser
    OptionParser.new do |opts|
      opts.banner = 'Usage: jobber.rb [options]'

      opts.on('-q', '--quiet', 'Only display anything if there are errors.') do
        @verbosity = :problems
      end

      opts.on('-s', '--solve', 'Try to automagically solve the problems') do
        @mode = :destroy
      end
    end
  end

  def check_job_paths
    bad = 0
    @job_paths.each do |path|
      unless path.directory?
        bad += 1
        $stderr.puts "'#{path}' is not a directory."
      end
    end
    fail 'I need directories to scan!' if bad > 0
  end

  def jobs
    @jobs ||= @job_paths.map { |p| Job.new p }
  end

  def problems?
    @problem_count > 0
  end

  def scan
    @problem_count = 0
    print 'Scanning: '
    jobs.each do |job|
      job.scan_builds
      # p job
      # p job.next_build_number

      if job.problem?
        @problem_count += 1
        print '*'
      else
        print '.'
      end
    end
    puts
  end

  def solve
    return unless problems?

    puts
    if mode == :destroy
      puts '**** SOLUTIONS ****'
      soln_str = 'Solving with'
    else
      puts '**** PROBLEMS ****'
      soln_str = 'Proposal'
    end

    jobs.each do |job|
      if job.problem?
        puts "#{job.name}:"
        job.problems.each do |problem|
          puts " Problem: #{problem}"
        end
        job.solutions.each do |solution|
          puts " #{soln_str}: #{solution}"
          solution.solve if :destroy == mode
        end
      end
    end

    puts
    puts "Found #{@problem_count} problem jobs."
  end

  def run
    @job_paths = parser.parse!(args).uniq.map { |p| Pathname.new p }

    check_job_paths

    begin
      @original_stdout = $stdout
      if verbosity == :all
        $stdout.sync = true # unbuffered output
      else
        $stdout = @stored_stdout = StringIO.new
      end

      scan
      solve
    ensure
      $stdout = @original_stdout
      print @stored_stdout.string if problems? && verbosity != :all
    end

    problems?
  end
end

if $PROGRAM_NAME == __FILE__
  app = Application.new(ARGV)
  app.run
  exit(app.problems? ? 1 : 0)
end
