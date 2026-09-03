use v5.12;
use strict;
use warnings;
use Test::More;
use File::Path qw/make_path/;
use File::Temp qw/tempdir/;
use JSON::PP qw/decode_json/;

my $tmp = tempdir(CLEANUP => 1);
my $root = "$tmp/root";
my $scriptdir = "$tmp/asgs";
my $rundir = "$tmp/run";
make_path("$root/available", "$root/active", "$root/adapters/available", "$root/adapters/active");
make_path($scriptdir, $rundir);

my $check = "$root/available/050-details";
open my $ch, q{>}, $check or die $!;
print {$ch} <<'SH';
#!/usr/bin/env bash
printf '%s\n' '{"schema":1,"type":"test_details","value":42}' > "$ASGS_MON_RESULT_FILE"
echo "details check ok"
echo "second diagnostic line"
exit 0
SH
close $ch;
chmod 0755, $check;
symlink q{../available/050-details}, "$root/active/050-details" or die $!;

my $config = "$tmp/asgs_config_test.sh";
open my $cfh, q{>}, $config or die $!;
print {$cfh} "HPCENVSHORT=test\n";
close $cfh;

my $state = "$tmp/test.state";
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

my $once = qx{$^X bin/asgs-mon --once --pid $asgs_pid --delay 1 --no-notify --silent 2>&1};
is($? >> 8, 0, q{monitor pass with structured details exits zero});
my @status = glob("$tmp/asgs-mon-*.status.json");
is(scalar(@status), 1, q{status snapshot was written});
if (@status) {
    open my $fh, q{<}, $status[0] or die $!;
    local $/;
    my $data = decode_json(<$fh>);
    close $fh;
    is($data->{checks}->{q{050-details}}->{details}->{type}, q{test_details}, q{structured check type survives into status JSON});
    is($data->{checks}->{q{050-details}}->{details}->{value}, 42, q{structured check payload survives into status JSON});
}

my $diag = qx{$^X bin/asgs-mon --check 050 --pid $asgs_pid --no-notify 2>&1};
is($? >> 8, 0, q{--check exits zero});
like($diag, qr/details check ok.*second diagnostic line/s, q{--check displays complete human-readable check output});

kill q{TERM}, $asgs_pid;
waitpid($asgs_pid, 0);

done_testing;
