jenkins-job-checker
===================

A stupid simple script to check for problems with job data on disk.

This was written to combat problems we've been having with builds
disappearing after the build completed as well as some other problems
we've had over the years (cruft can really build up in your jobs!).

Usage:
------

Point it at a directory in `$JENKINS_HOME/jobs` and it will scan that
job's build history:

    $ ruby jobber.rb "$JENKINS_HOME/jobs/MyJob"

It will then print out any problems it finds and solutions it proposes.

It is reasonable to run it on all jobs:

    $ ruby jobber.rb "$JENKINS_HOME/jobs/"*

### Automatic fixing of problems

**WARNING** I tried my best not to break anything. You do have good
backups, right?

You can let `jobber.rb` try to fix those problems itself:

    $ ruby jobber.rb "$JENKINS_HOME/jobs/MyJob" --solve

It'll then run its proposed solutions.

**Note:** You need to either restart Jenkins, "reload from disk", or
better yet, run `jobber.rb --solve` while Jenkins is down.

See Also:
---------

-   [Builds disappear from build history after
    completion](https://issues.jenkins-ci.org/browse/JENKINS-15156)
-   [Duplicate build numbers in the Build
    History](https://issues.jenkins-ci.org/browse/JENKINS-11853)
-   [Builds and workspace disappear for jobs created after upgrade to
    1.487](https://issues.jenkins-ci.org/browse/JENKINS-15719)
