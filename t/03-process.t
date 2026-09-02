use v5.12;
use strict;
use warnings;
use Test::More;
use File::Temp qw/tempdir/;
use File::Path qw/make_path/;
use File::Spec;

my $tmp = tempdir(CLEANUP => 1);
my $scriptdir = "$tmp/asgs";
my $scratch   = "$tmp/scratch";
my $rundir    = "$scratch/run";
make_path($scriptdir, $scratch, "$rundir/status");

my $config = "$tmp/asgs_config_test.sh";
open my $cfh, q{>}, $config or die $!;
print {$cfh} "HPCENVSHORT=test\n";
close $cfh;

my $state = "$scratch/test.state";
open my $sfh, q{>}, $state or die $!;
print {$sfh} "RUNDIR=$rundir\n";
print {$sfh} "SCRIPTDIR=$scriptdir\n";
print {$sfh} "HPCENV=test\n";
print {$sfh} "HPCENVSHORT=test\n";
print {$sfh} "ADVISORY=initialize\n";
close $sfh;

my $fake = "$tmp/asgs_main.sh";
open my $ffh, q{>}, $fake or die $!;
print {$ffh} "#!/usr/bin/env bash\nsleep 30\n";
close $ffh;
chmod 0755, $fake;

my $pid = fork();
die "fork failed" if not defined $pid;
if ($pid == 0) {
    open STDOUT, q{>}, q{/dev/null};
    open STDERR, q{>}, q{/dev/null};
    exec q{bash}, $fake, $config;
    exit 127;
}
sleep 1;

local %ENV = %ENV;
$ENV{_ASGSH_CURRENT_PROFILE} = q{test-profile};
$ENV{ASGS_CONFIG} = $config;
$ENV{STATEFILE} = $state;
$ENV{SCRIPTDIR} = $scriptdir;
$ENV{HPCENV} = q{test};
$ENV{HPCENVSHORT} = q{test};
$ENV{ASGS_TMPDIR} = $tmp;

my $out = qx{$^X bin/asgs-mon --check 000 --pid $pid --no-notify 2>&1};
my $rc = $? >> 8;

kill q{TERM}, $pid;
waitpid($pid, 0);

is($rc, 0, q{validated fake asgs_main process passes 000 check});
like($out, qr/Found asgs_main\.sh/, q{000 check confirms process});

done_testing;
