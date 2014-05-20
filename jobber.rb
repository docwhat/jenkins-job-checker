#!/usr/bin/env ruby

# rubocop:disable MethodLength

require 'pathname'
require 'time'

# Comment
class DateBuild
  def number
    # load build.xml and get XPath /*/number/text()
  end
end

# Comment
class Job
  attr_reader :path, :numbers, :dates, :problems

  def initialize(path)
    @path = Pathname.new path
    @problems = []
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

    # p @dates
    # p @numbers
  end

  def problem?
    return false if numbers.length == 0 && dates.length == 0

    test_next_build_number
    test_broken_number_link
    test_numbers_are_not_files
    test_last_links
    test_dates_for_numbers_are_in_order

    return problems.length > 0
    # assert dates.map(&:number).length == dates.map(&:number).uniq.length
    # assert dates.length == numbers.length
    # @date_bucket.length != @number_bucket.length
  end

  def next_build_number
    @next_build_number ||= Integer((path + 'nextBuildNumber').read)
  end

  def problem message
    @problems << message
  end

  def test_last_links
    links = %w(lastFailedBuild lastStableBuild lastSuccessfulBuild lastUnstableBuild lastUnsuccessfulBuild)

    links.map { |l| builds_path + l }.each do |path|
      problem "#{path} should be a symlink but isn't." if ! path.symlink? && path.exist?
    end
  end

  def test_numbers_are_not_files
    bad = []
    numbers.each do |n|
      link = builds_path + n.to_s
      problem "The number link #{link} is not a symlink!" unless link.symlink?
    end
  end

  def test_broken_number_link
    # numbers.map(&:link?).reduce(true) { |a, e| a && e }
    bad = []
    numbers.each do |n|
      link = builds_path + n.to_s
      problem "The number link #{link} is broken." unless link.exist?
    end
  end

  def test_dates_for_numbers_are_in_order
    # numbers.sort.each { |n| assert n.date > (prev_n).date }
    # numbers_dates = numbers.map { |n| builds_path + n.to_s }.select(&:symlink?).select(&:exist?).map do |p|
    #   p.readlink.basename.to_s.match(/^(\d{4}-\d{2}-\d{2})_(\d{2})-(\d{2})-(\d{2})$/)
    # end.map do |m|
    #   Time.parse "#{m[1]} #{m[2]}:#{m[3]}:#{m[4]}"
    # end
    numbers_dates = numbers.map { |n| builds_path + n.to_s }.select(&:symlink?).select(&:exist?).map do |p|
      [p, p.readlink.basename.to_s.match(/^(\d{4}-\d{2}-\d{2})_(\d{2})-(\d{2})-(\d{2})$/)]
    end.map do |p, m|
      [p, Time.parse("#{m[1]} #{m[2]}:#{m[3]}:#{m[4]}")]
    end

    numbers_dates.each_with_index do |path_and_date, i|
      path, date = path_and_date
      problem "The link #{path} -> #{path.readlink} is out of order." if date > numbers_dates.map(&:last)[i..-1].min
    end
    # if numbers_dates != numbers_dates.sort
    #   problem "The number links are out of order!"
    # end
  end

  def test_next_build_number
    # assert next_build_number == numbers.sort.last + 1
    given = next_build_number
    expected = numbers.last + 1
    if given < expected
      problem "The nextBuildNumber is set to #{given} but I expected at least #{expected}"
    end
  end
end

if $PROGRAM_NAME == __FILE__
  if ARGV.map { |p| File.directory? p }.reduce(true) { |a, e| a && e }
    all_problems = {}
    ARGV.each do |path|
      puts " ** #{path} **"
      job = Job.new path
      job.scan_builds
      # p job.next_build_number

      all_problems[File.basename path] = job.problems if job.problem?
    end

    if all_problems.length > 0
      count = 0
      puts
      puts "**** PROBLEMS ****"
      all_problems.keys.sort.each do |key|
        puts "#{key}:"
        all_problems[key].each do |problem|
          puts " * #{problem}"
          count += 1
        end
      end

      puts
      puts "Found #{count} problems."
    else
      puts "No problems!"
    end
  else
    fail "You need to give me a 'build' style directory."
  end
end
