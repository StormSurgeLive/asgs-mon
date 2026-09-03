use v5.12;
use strict;
use warnings;
use Test::More;
use File::Temp qw/tempdir/;
use File::Path qw/make_path/;
use File::Spec;

my $tmp = tempdir(CLEANUP => 1);
my $root = "$tmp/root";
my $scriptdir = "$tmp/asgs";
my $scratch = "$tmp/scratch";
my $rundir = "$scratch/run";
make_path("$root/available", "$root/active", "$root/adapters/available", "$root/adapters/active");
make_path($scriptdir, $scratch, $rundir, "$tmp/bin");

my $check = "$root/available/001-warning";
open my $ch, q{>}, $check or die $!;
print {$ch} <<'SH';
#!/usr/bin/env bash
echo "test warning subject"
echo
echo "still broken"
exit 1
SH
close $ch;
chmod 0755, $check;
symlink q{../available/001-warning}, "$root/active/001-warning" or die $!;

my $config = "$tmp/asgs_config_test.sh";
open my $cfh, q{>}, $config or die $!;
print {$cfh} "HPCENVSHORT=test\n";
close $cfh;

my $state = "$scratch/test.state";
open my $sfh, q{>}, $state or die $!;
print {$sfh} "RUNDIR=$rundir\nSCRIPTDIR=$scriptdir\nHPCENV=test\nHPCENVSHORT=test\nADVISORY=initialize\n";
close $sfh;

my $global = "$tmp/asgs-global.conf";
open my $gfh, q{>}, $global or die $!;
print {$gfh} "[monitor]\nnotify_email=test\@example.org\n";
close $gfh;

my $mail_log = "$tmp/mail.log";
my $sendmail = "$tmp/bin/asgs-sendmail";
open my $mfh, q{>}, $sendmail or die $!;
print {$mfh} <<"SH";
#!/usr/bin/env bash
cat >/dev/null
echo sent >> "$mail_log"
exit 0
SH
close $mfh;
chmod 0755, $sendmail;

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
$ENV{PATH} = "$tmp/bin:$ENV{PATH}";
$ENV{ASGS_MON_ROOT} = $root;
$ENV{_ASGSH_CURRENT_PROFILE} = q{test-profile};
$ENV{ASGS_CONFIG} = $config;
$ENV{STATEFILE} = $state;
$ENV{SCRIPTDIR} = $scriptdir;
$ENV{HPCENV} = q{test};
$ENV{HPCENVSHORT} = q{test};
$ENV{ASGS_TMPDIR} = $tmp;

my $cmd_rc = system(
    $^X, q{bin/asgs-mon},
    q{--pid}, $asgs_pid,
    q{--delay}, 1,
    q{--passes}, 3,
    q{--hush}, 60,
    q{--global-config}, $global,
    q{--silent}
);

kill q{TERM}, $asgs_pid;
waitpid($asgs_pid, 0);

is($cmd_rc >> 8, 0, q{finite monitor run exits successfully});

my $count = 0;
if (open my $lfh, q{<}, $mail_log) {
    $count++ while <$lfh>;
    close $lfh;
}

is($count, 1, q{persistent WARNING sends one email inside hush window});

done_testing;
