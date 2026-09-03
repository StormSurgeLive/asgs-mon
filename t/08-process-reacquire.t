use v5.12;
use strict;
use warnings;
use Test::More;
use File::Temp qw/tempdir/;
use File::Path qw/make_path/;

my $tmp = tempdir(CLEANUP => 1);
my $root = "$tmp/root";
my $scriptdir = "$tmp/asgs";
my $scratch = "$tmp/scratch";
my $rundir = "$scratch/run";
make_path("$root/available", "$root/active", "$root/adapters/available", "$root/adapters/active");
make_path($scriptdir, $scratch, $rundir);

for my $name (qw/000-asgs_main-pid-check _bash-helper-functions.sh/) {
    my $src = "available/$name";
    my $dst = "$root/available/$name";
    open my $in, q{<}, $src or die $!;
    open my $out, q{>}, $dst or die $!;
    print {$out} $_ while <$in>;
    close $out;
    close $in;
    chmod(($name =~ /^000-/ ? 0755 : 0644), $dst);
}
symlink q{../available/000-asgs_main-pid-check}, "$root/active/000-asgs_main-pid-check" or die $!;

my $config = "$tmp/asgs_config_test.sh";
open my $cfh, q{>}, $config or die $!;
print {$cfh} "HPCENVSHORT=test\n";
close $cfh;

my $state = "$scratch/test.state";
open my $sfh, q{>}, $state or die $!;
print {$sfh} "RUNDIR=$rundir\nSCRIPTDIR=$scriptdir\nHPCENV=test\nHPCENVSHORT=test\nADVISORY=initialize\n";
close $sfh;

my $fake = "$tmp/asgs_main.sh";
open my $ffh, q{>}, $fake or die $!;
print {$ffh} <<'SH';
#!/usr/bin/env bash
trap 'exit 0' TERM INT
while :; do sleep 1; done
SH
close $ffh;
chmod 0755, $fake;

sub start_asgs {
    my $pid = fork();
    die "fork failed" if not defined $pid;
    if ($pid == 0) {
        open STDOUT, q{>}, q{/dev/null};
        open STDERR, q{>}, q{/dev/null};
        exec q{bash}, $fake, q{-c}, $config;
        exit 127;
    }
    select undef, undef, undef, 0.20;
    return $pid;
}

local %ENV = %ENV;
$ENV{ASGS_MON_ROOT} = $root;
$ENV{_ASGSH_CURRENT_PROFILE} = q{test-profile};
$ENV{ASGS_CONFIG} = $config;
$ENV{STATEFILE} = $state;
$ENV{SCRIPTDIR} = $scriptdir;
$ENV{HPCENV} = q{test};
$ENV{HPCENVSHORT} = q{test};
$ENV{ASGS_TMPDIR} = $tmp;

my $first = start_asgs();
my $log = "$tmp/monitor.log";
my $monitor = fork();
die "fork failed" if not defined $monitor;
if ($monitor == 0) {
    open STDOUT, q{>}, $log or die $!;
    open STDERR, q{>&STDOUT} or die $!;
    exec $^X, q{bin/asgs-mon}, q{--delay}, 1, q{--passes}, 6, q{--no-notify}, q{--silent};
    exit 127;
}

# Let at least one normal pass complete, then leave one pass with no ASGS
# process before starting the same profile again under a new PID.
select undef, undef, undef, 1.30;
kill q{TERM}, $first;
waitpid($first, 0);
select undef, undef, undef, 1.30;
my $second = start_asgs();

waitpid($monitor, 0);
my $monitor_rc = $? >> 8;
kill q{TERM}, $second;
waitpid($second, 0);

open my $lfh, q{<}, $log or die $!;
local $/;
my $output = <$lfh>;
close $lfh;

is($monitor_rc, 0, q{monitor stays alive through ASGS restart});
like($output, qr/waiting for restart under this profile/, q{monitor enters waiting state when old PID disappears});
like($output, qr/ASGS process reacquired: pid \Q$first\E -> \Q$second\E/, q{monitor automatically adopts new PID});
like($output, qr/NOTICE ASGS process restarted/, q{000 check reports one restart/recovery transition});

done_testing;
