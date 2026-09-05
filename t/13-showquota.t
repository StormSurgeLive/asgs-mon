use v5.12;
use strict;
use warnings;
use Test::More;
use File::Temp qw/tempdir/;
use JSON::PP qw/decode_json/;

my $tmp = tempdir(CLEANUP => 1);
my $bin = "$tmp/bin";
mkdir $bin or die $!;
my $fixture = "$tmp/showquota.txt";
my $rcfile = "$tmp/showquota.rc";
my $fake = "$bin/showquota";

open my $fh, q{>}, $fake or die $!;
print {$fh} <<'SH';
#!/usr/bin/env bash
cat "$SHOWQUOTA_FIXTURE"
rc=0
[[ -r "$SHOWQUOTA_RCFILE" ]] && rc=$(cat "$SHOWQUOTA_RCFILE")
exit "$rc"
SH
close $fh;
chmod 0755, $fake;

my $check = q{available/014-showquota};

sub run_case {
    my (%arg) = @_;
    open my $q, q{>}, $fixture or die $!;
    print {$q} $arg{text};
    close $q;
    open my $r, q{>}, $rcfile or die $!;
    print {$r} defined($arg{showquota_rc}) ? $arg{showquota_rc} : 0;
    close $r;

    my $details = "$tmp/details.json";
    unlink $details;

    local %ENV = %ENV;
    $ENV{PATH} = "$bin:$ENV{PATH}";
    $ENV{SHOWQUOTA_FIXTURE} = $fixture;
    $ENV{SHOWQUOTA_RCFILE} = $rcfile;
    $ENV{ASGS_MON_RESULT_FILE} = $details;
    $ENV{ASGS_MON_PROFILE} = q{quota-test};
    $ENV{ASGS_MON_HPCENVSHORT} = $arg{hpcshort} // q{queenbeeC};
    $ENV{ASGS_MON_HPCENV} = $arg{hpcenv} // q{qbc.loni.org};
    delete $ENV{ASGS_MON_SHOWQUOTA_WARN};
    delete $ENV{ASGS_MON_SHOWQUOTA_CRIT};

    my $out = qx{$^X $check '' '' 1 10 quota-test '' '' 1 2>&1};
    my $rc = $? >> 8;
    my $data;
    if (-r $details) {
        open my $d, q{<}, $details or die $!;
        local $/;
        $data = decode_json(<$d>);
        close $d;
    }
    return ($rc, $out, $data);
}

my $normal = <<'EOF';
User filesystem quotas for estrabd (uid 1238):
     Filesystem         MB used    MB quota       files      fquota
     /home                  784       10000       16911           0
     /work /project     7906649           0     1484392     4000000

Storage allocation      MB used    MB quota       files  expiration
     sa_cera              27661      100000       84505  2027-03-18

CPU Allocation SUs:        remaining   allocated  expiration
    loni_cera_2026:       3033748.42  3500000.00  2027-07-01
EOF

{
    my ($rc, $out, $d) = run_case(text => $normal);
    is($rc, 0, q{normal LSU/LONI quota report is OK});
    like($out, qr/Resource:\s+QueenBeeC/, q{known HPCENVSHORT maps to QueenBeeC});
    like($out, qr{/home\s+784 / 10000 MB\s+7\.84%\s+OK}, q{/home MB quota percentage is reported});
    like($out, qr{/work /project files\s+1484392 / 4000000 files\s+37\.11%\s+OK}, q{/work /project file quota percentage is reported});
    unlike($out, qr{/work /project\s+7906649 / 0 MB}, q{zero MB quota is not treated as a percentage quota});
    like($out, qr{sa_cera\s+27661 / 100000 MB\s+27\.66%\s+OK}, q{storage percentage is reported});
    like($out, qr{loni_cera_2026\s+466251\.58 / 3500000 SU\s+13\.32%\s+OK}, q{CPU used is allocated minus remaining});
    is($d->{notify} ? 1 : 0, 0, q{normal report does not request email});
    is($d->{highest}->{cpu}->{name}, q{loni_cera_2026}, q{highest CPU allocation is explicit});
    is($d->{highest}->{storage}->{name}, q{sa_cera}, q{highest storage allocation is explicit});
}

{
    my $text = <<'EOF';
Storage allocation MB used MB quota files expiration
 sa_low 100 1000 1 2027-01-01
 sa_high 800 1000 1 2027-01-01
CPU Allocation SUs: remaining allocated expiration
 hpc_low: 900 1000 2027-01-01
 hpc_high: 200 1000 2027-01-01
EOF
    my ($rc, $out, $d) = run_case(
        text => $text,
        hpcshort => q{supermic},
        hpcenv => q{supermic.hpc.lsu.edu},
    );
    is($rc, 1, q{greater than 75 percent is WARNING});
    like($out, qr/Resource:\s+SuperMIC/, q{SuperMIC mapping is reported});
    like($out, qr/Highest storage allocation: sa_high 80\.00% WARNING/, q{highest storage allocation selected});
    like($out, qr/Highest CPU\/SU allocation: hpc_high 80\.00% WARNING/, q{highest CPU allocation selected});
    is($d->{notify} ? 1 : 0, 0, q{warnings do not request email});
}


{
    my $text = <<'EOF';
Storage allocation MB used MB quota files expiration
 sa_cera 750 1000 1 2027-01-01
CPU Allocation SUs: remaining allocated expiration
 loni_cera_2026: 250 1000 2027-01-01
EOF
    my ($rc, $out, $d) = run_case(text => $text);
    is($rc, 0, q{exactly 75 percent remains OK});
    like($out, qr/75\.00%\s+OK/, q{75 percent boundary is reported as OK});
}

{
    my $text = <<'EOF';
Storage allocation MB used MB quota files expiration
 sa_cera 950 1000 1 2027-01-01
CPU Allocation SUs: remaining allocated expiration
 loni_cera_2026: 50 1000 2027-01-01
EOF
    my ($rc, $out, $d) = run_case(text => $text);
    is($rc, 1, q{exactly 95 percent remains WARNING});
    like($out, qr/95\.00%\s+WARNING/, q{95 percent boundary is not CRITICAL});
    is($d->{notify} ? 1 : 0, 0, q{95 percent exactly does not request combined email});
}

{
    my $text = <<'EOF';
Storage allocation MB used MB quota files expiration
 sa_cera 100 1000 1 2027-01-01
CPU Allocation SUs: remaining allocated expiration
 hpc_cera_2026: 10 1000 2027-07-01
EOF
    my ($rc, $out, $d) = run_case(
        text => $text,
        hpcshort => q{mike},
        hpcenv => q{mike.hpc.lsu.edu},
    );
    is($rc, 2, q{CPU alone above 95 percent is CRITICAL});
    like($out, qr{hpc_cera_2026\s+990 / 1000 SU\s+99\.00%\s+CRITICAL}, q{LSU HPC CPU allocation format parses});
    is($d->{notify} ? 1 : 0, 0, q{CPU-only critical does not request combined allocation email});
}

{
    my $text = <<'EOF';
Storage allocation MB used MB quota files expiration
 sa_cera 990 1000 1 2027-01-01
CPU Allocation SUs: remaining allocated expiration
 loni_cera_2026: 900 1000 2027-01-01
EOF
    my ($rc, $out, $d) = run_case(text => $text);
    is($rc, 2, q{storage alone above 95 percent is CRITICAL});
    is($d->{notify} ? 1 : 0, 0, q{storage-only critical does not request combined allocation email});
}

{
    my $text = <<'EOF';
Storage allocation MB used MB quota files expiration
 sa_cera 990 1000 1 2027-01-01
CPU Allocation SUs: remaining allocated expiration
 loni_cera_2026: 10 1000 2027-01-01
EOF
    my ($rc, $out, $d) = run_case(text => $text);
    is($rc, 2, q{both allocations above 95 percent are CRITICAL});
    is($d->{notify} ? 1 : 0, 1, q{both allocations above 95 percent request email});
    ok($d->{combined_allocation_alert}, q{combined allocation alert is explicit in JSON});
}

{
    my $text = <<'EOF';
Storage allocation MB used MB quota files expiration
 sa_cera 500 1000 1 2027-01-01
EOF
    my ($rc, $out, $d) = run_case(text => $text);
    is($rc, 0, q{missing CPU section is safe when available resources are OK});
    like($out, qr/CPU allocation:\s+n\/a/, q{missing CPU section is explicit});
    like($out, qr/No CPU\/SU allocation section was reported/, q{missing CPU section is noted});
    is($d->{notify} ? 1 : 0, 0, q{missing section never requests combined email});
}

{
    my ($rc, $out, $d) = run_case(text => $normal, showquota_rc => 9);
    is($rc, 3, q{showquota failure is UNKNOWN});
    like($out, qr/UNKNOWN showquota failed/, q{showquota failure is explained});
    is($d->{notify} ? 1 : 0, 0, q{showquota failure does not request email});
}

{
    local %ENV = %ENV;
    my $empty = tempdir(CLEANUP => 1);
    $ENV{PATH} = $empty;
    $ENV{ASGS_MON_PROFILE} = q{quota-test};
    $ENV{ASGS_MON_HPCENVSHORT} = q{qbd};
    $ENV{ASGS_MON_HPCENV} = q{qbd.loni.org};
    my $out = qx{$^X $check '' '' 1 10 quota-test '' '' 1 2>&1};
    is($? >> 8, 0, q{missing showquota is skipped/OK});
    like($out, qr/skipped: showquota is not available/, q{verbose skip explains missing command});
}

done_testing;
