#!/usr/bin/env perl
use v5.12;
use strict;
use warnings;

use JSON::PP qw/decode_json encode_json/;

use constant {
    OK       => 0,
    WARNING  => 1,
    CRITICAL => 2,
    UNKNOWN  => 3,
    NOTIFY   => 4,
};

my ($oldout, $oldexit, $count, $delay, $profile, $config, $statefile, $verbose) = @ARGV;

$profile = $ENV{ASGS_MON_PROFILE} if exists $ENV{ASGS_MON_PROFILE};
my $rundir = $ENV{ASGS_MON_RUNDIR};

if (not defined $rundir or $rundir eq q{}) {
    print "(unknown $profile - perl-example) UNKNOWN RUNDIR is not available\n\n";
    print "The loaded ASGS state does not currently provide RUNDIR.\n";
    exit UNKNOWN;
}

print encode_json({ checked => time });
exit OK;
