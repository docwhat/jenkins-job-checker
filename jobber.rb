#!/usr/bin/env ruby

require 'optparse'
require 'fileutils'
require 'pathname'
require 'time'

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
      case child.basename.to_s
      when /^(\d+)$/
        @numbers << Integer(Regexp.last_match(1))
      when /^(\d{4}-\d{2}-\d{2})_(\d{2})-(\d{2})-(\d{2})$/
        m = Regexp.last_match
        @dates << Time.parse("#{m[1]} #{m[2]}:#{m[3]}:#{m[4]}")
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
    # assert dates.map(&:number).length == dates.map(&:number).uniq.length
  end

  def next_build_number
    @next_build_number ||= Integer((path + 'nextBuildNumber').read)
  end

  def problem(message)
    @problems << message
  end

  def solution(&block)
    @solutions << block
  end

  def test_is_a_job_directory
    unless (path + 'config.xml').exist?
      problem "#{path} is not a job directory; 'config.xml' is missing."
    end
  end

  def test_last_links_should_be_links
    links = %w(lastFailedBuild lastStableBuild lastSuccessfulBuild lastUnstableBuild lastUnsuccessfulBuild)

    links.map { |l| builds_path + l }.select { |p| !p.symlink? && p.exist? }.each do |path|
      problem "#{path} should be a symlink but isn't."

      solution do
        path.rmtree if path.directory?
        path.unlink if path.exist?
        File.symlink '-1', path.to_s
      end
    end
  end

  def test_numbers_are_not_files
    numbers.each do |n|
      link = builds_path + n.to_s
      problem "The number link #{link} is not a symlink!" unless link.symlink?
    end
  end

  def test_broken_number_link
    # numbers.map(&:link?).reduce(true) { |a, e| a && e }
    numbers.map { |n| builds_path + n.to_s }.reject(&:exist?).each do |link|
      problem "The number link #{link} is broken."
      solution { link.unlink if link.exist? }
    end
  end

  def test_dates_for_numbers_are_in_order
    valid_numbers_paths = numbers.map { |n| builds_path + n.to_s }.select(&:symlink?).select(&:exist?)

    valid_numbers_dates = valid_numbers_paths.map do |path|
      m = path.readlink.basename.to_s.match(/^(\d{4}-\d{2}-\d{2})_(\d{2})-(\d{2})-(\d{2})$/)
      Time.parse("#{m[1]} #{m[2]}:#{m[3]}:#{m[4]}")
    end

    numbers_paths_and_dates = valid_numbers_paths.zip(valid_numbers_dates)

    numbers_paths_and_dates.each_with_index do |path_and_date, i|
      path, date = path_and_date
      if date > numbers_paths_and_dates.map(&:last)[i..-1].min
        problem "The link #{path} -> #{path.readlink} is out of order."
      end
    end
    # if numbers_dates != numbers_dates.sort
    #   problem "The number links are out of order!"
    # end
  end

  def test_numbers_equals_dates
    # assert dates.length == numbers.length
    if dates.length > numbers.length
      problem 'There are more dates files than numbers files.'
    elsif dates.length < numbers.length
      problem 'There are more numbers files than dates files.'
    end
  end

  def test_next_build_number
    # assert next_build_number == numbers.sort.last + 1
    return if dates.empty? && numbers.empty?
    given = next_build_number
    expected = numbers.last + 1
    if given < expected
      problem "The nextBuildNumber is set to #{given} but I expected at least #{expected}"
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
        print '!'
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

      if :destroy == mode
        puts
        puts '**** SOLUTIONS ****'
        all_solutions.keys.sort.each do |key|
          print "Fixing #{key}: "
          all_solutions[key].each { |solution| solution.call }
          puts 'done.'
        end
      end
    else
      puts 'No problems!'
    end
  else
    fail "You need to give me a 'build' style directory."
  end
end
