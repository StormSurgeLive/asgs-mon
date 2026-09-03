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

my $check = "$root/available/001-slow";
open my $ch, q{>}, $check or die $!;
print {$ch} <<'SH';
#!/usr/bin/env bash
sleep 10
echo impossible
exit 0
SH
close $ch;
chmod 0755, $check;

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
print {$ffh} "#!/usr/bin/env bash\nsleep 30\n";
close $ffh;
chmod 0755, $fake;

my $asgs_pid = fork();
die "fork failed" if not defined $asgs_pid;
if ($asgs_pid == 0) {
    open STDOUT, q{>}, q{/dev/null};
    open STDERR, q{>}, q{/dev/null};
    exec q{bash}, $fake, q{-c}, $config;
    exit 127;
}
sleep 1;

local %ENV = %ENV;
$ENV{ASGS_MON_ROOT} = $root;
$ENV{_ASGSH_CURRENT_PROFILE} = q{test-profile};
$ENV{ASGS_CONFIG} = $config;
$ENV{STATEFILE} = $state;
$ENV{SCRIPTDIR} = $scriptdir;
$ENV{HPCENV} = q{test};
$ENV{HPCENVSHORT} = q{test};
$ENV{ASGS_TMPDIR} = $tmp;

my $started = time;
my $out = qx{$^X bin/asgs-mon --check 001 --pid $asgs_pid --timeout 1 --no-notify 2>&1};
my $rc = $? >> 8;
my $elapsed = time - $started;

kill q{TERM}, $asgs_pid;
waitpid($asgs_pid, 0);

is($rc, 3, q{timed out check becomes UNKNOWN});
like($out, qr/check timed out/i, q{timeout result is explained});
ok($elapsed < 6, q{timeout stops the slow check promptly});

done_testing;
