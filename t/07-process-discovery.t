use v5.12;
use strict;
use warnings;
use Test::More;
use File::Temp qw/tempdir/;
use File::Path qw/make_path/;

my $tmp = tempdir(CLEANUP => 1);
my $scriptdir = "$tmp/asgs";
my $scratch = "$tmp/scratch";
my $rundir = "$scratch/run";
make_path($scriptdir, $scratch, $rundir);

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
sleep "${ASGS_FAKE_LIFETIME:-30}"
SH
close $ffh;
chmod 0755, $fake;

sub start_asgs {
    my ($lifetime, $which_config) = @_;
    $which_config //= $config;
    my $pid = fork();
    die "fork failed" if not defined $pid;
    if ($pid == 0) {
        $ENV{ASGS_FAKE_LIFETIME} = $lifetime;
        open STDOUT, q{>}, q{/dev/null};
        open STDERR, q{>}, q{/dev/null};
        exec q{bash}, $fake, q{-c}, $which_config;
        exit 127;
    }
    return $pid;
}

local %ENV = %ENV;
$ENV{_ASGSH_CURRENT_PROFILE} = q{test-profile};
$ENV{ASGS_CONFIG} = $config;
$ENV{STATEFILE} = $state;
$ENV{SCRIPTDIR} = $scriptdir;
$ENV{HPCENV} = q{test};
$ENV{HPCENVSHORT} = q{test};
$ENV{ASGS_TMPDIR} = $tmp;
$ENV{ASGS_MON_DISCOVERY_SETTLE_MS} = 500;

my $stable = start_asgs(30);
select undef, undef, undef, 0.10;
my $transient = start_asgs(0.25);

my $out = qx{$^X bin/asgs-mon --validate --no-notify 2>&1};
my $rc = $? >> 8;

kill q{KILL}, $stable;
waitpid($stable, 0);
waitpid($transient, 0);

is($rc, 0, q{transient duplicate does not make discovery ambiguous});
unlike($out, qr/multiple stable matching/, q{transient duplicate was filtered before ambiguity decision});
like($out, qr/OK(?: with warnings|: profile)/, q{validation completes normally});

# A different file with the same basename must not match this profile.
my $otherdir = "$tmp/other";
make_path($otherdir);
my $other_config = "$otherdir/asgs_config_test.sh";
open my $ofh, q{>}, $other_config or die $!;
print {$ofh} "HPCENVSHORT=other\n";
close $ofh;
my $wrong = start_asgs(30, $other_config);
select undef, undef, undef, 0.10;
my $wrong_out = qx{$^X bin/asgs-mon --validate --no-notify 2>&1};
my $wrong_rc = $? >> 8;
kill q{KILL}, $wrong;
waitpid($wrong, 0);
is($wrong_rc, 0, q{same-basename config process is not treated as this profile});
like($wrong_out, qr/no matching asgs_main\.sh -c process/, q{config matching uses the canonical path});

# Two genuinely stable roots for the exact config remain ambiguous.
my $one = start_asgs(30);
my $two = start_asgs(30);
select undef, undef, undef, 0.10;
my $amb_out = qx{$^X bin/asgs-mon --validate --no-notify 2>&1};
my $amb_rc = $? >> 8;
kill q{KILL}, $one;
kill q{KILL}, $two;
waitpid($one, 0);
waitpid($two, 0);
is($amb_rc, 1, q{two stable exact matches remain an error in validation});
like($amb_out, qr/multiple stable matching asgs_main\.sh -c processes/, q{genuine ambiguity is reported});

done_testing;
