use v5.12;
use strict;
use warnings;
use Test::More;
use File::Path qw/make_path/;
use File::Spec;
use File::Temp qw/tempdir/;
use FindBin qw/$Bin/;
use lib "$Bin/../lib";
use ASGS::Mon::ATCF qw/run_sanity_check/;

sub write_file {
    my ($path, $text) = @_;
    make_path(File::Spec->catdir((File::Spec->splitpath($path))[1])) if (File::Spec->splitpath($path))[1];
    open my $fh, q{>}, $path or die "$path: $!";
    print {$fh} $text;
    close $fh;
}

sub make_case {
    my (%opt) = @_;
    my $tmp = tempdir(CLEANUP => 1);
    my $scriptdir = "$tmp/asgs";
    my $rundir = "$tmp/run";
    my $last = "$tmp/last";
    make_path("$scriptdir/bin", $rundir, $last);

    my $adapter = "$scriptdir/bin/get_atcf_http.pl";
    my $fixture = $opt{fixture} || "$Bin/fixtures/atcf/al052026-healthy.fst";
    my $rss = $opt{rss} || "$Bin/fixtures/atcf/index-002A.xml";
    write_file($adapter, <<'MOCK');
#!/usr/bin/env perl
use strict; use warnings;
use File::Copy qw/copy/;
my %o;
while (@ARGV) { my $k=shift @ARGV; my $v=shift @ARGV; $k =~ s/^--//; $o{$k}=$v; }
copy($ENV{MOCK_ATCF_FIXTURE}, sprintf("al%02d%s.fst",$o{storm},$o{year})) or die $!;
copy($ENV{MOCK_RSS_FIXTURE}, "index-at.xml") or die $!;
print(($ENV{MOCK_ADAPTER_ADV} // "02"), "\n");
exit 0;
MOCK
    chmod 0755, $adapter;

    my $config = "$tmp/asgs_config_test.sh";
    write_file($config, qq{TROPICALCYCLONE=on\nSTORM="05"\nYEAR="2026"\nTRIGGER="rssembedded"\nGET_ATCF_SCRIPT="\$SCRIPTDIR/bin/get_atcf_http.pl"\nRSSSITE="tools.example/replay/data/al052026"\nFTPSITE="tools.example"\nFDIR="/atcf/afst"\nHDIR="/replay/data/al052026/atcf/btk"\nCOLDSTARTDATE="2026080406"\nHINDCASTLENGTH=30.0\nTIMESTEPSIZE=2.0\n});

    my $state = "$tmp/test.state";
    my $hstime = defined($opt{hstime}) ? $opt{hstime} : 2592000;
    my $state_adv = defined($opt{state_advisory}) ? $opt{state_advisory} : q{002A};
    write_file($state, qq{RUNDIR=$rundir\nSCRIPTDIR=$scriptdir\nADVISORY=$state_adv\nCYCLE=$state_adv\nCOLDSTARTDATE=2026080406\nHINDCASTLENGTH=30.0\nHSTIME=$hstime\nLASTSUBDIR=$last\n});
    write_file("$rundir/sentinel", "do not touch\n");

    if ($opt{collapsed}) {
        make_path("$rundir/$state_adv/veerRight75");
        write_file("$rundir/$state_adv/veerRight75/run.properties", <<'PROPS');
RunStartTime : 2026090306
RunEndTime : 2026090306
ColdStartTime : 2026080406
InitialHotStartTime : 2592000
adcirc.control.physics.rnday : 30.0000462962963
adcirc.timestepsize : 2.0
PROPS
    }

    if ($opt{live_duplicates}) {
        for my $scenario (qw/status nowcast nhcConsensus/) {
            make_path("$rundir/$state_adv/$scenario");
            write_file("$rundir/$state_adv/$scenario/run.properties", <<'PROPS');
RunStartTime : 2026090306
RunEndTime : 2026090306
ColdStartTime : 2026080406
InitialHotStartTime : 2592000
adcirc.control.physics.rnday : 30.0000462962963
adcirc.timestepsize : 2.0
PROPS
        }
        write_file("$rundir/$state_adv/nowcast/nowcast.run-control.properties", <<'PROPS');
RunStartTime : 2026090306
RunEndTime : 2026090306
ColdStartTime : 2026080406
InitialHotStartTime : 2592000
adcirc.control.physics.rnday : 30.0000462962963
PROPS
        write_file("$rundir/$state_adv/nhcConsensus/nhcConsensus.run-control.properties", <<'PROPS');
RunStartTime : 2026090306
RunEndTime : 2026090306
ColdStartTime : 2026080406
InitialHotStartTime : 2592000
adcirc.control.physics.rnday : 30.0000462962963
PROPS
        make_path("$rundir/$state_adv/wind10m");
        write_file("$rundir/$state_adv/wind10m/wind10m.run-control.properties", <<'PROPS');
RunStartTime : 2026090306
RunEndTime : 2026090306
ColdStartTime : 2026080406
InitialHotStartTime : 2592000
adcirc.control.physics.rnday : 30.0069444444444
PROPS
    }

    local %ENV = %ENV;
    $ENV{ASGS_MON_CONFIG} = $config;
    $ENV{ASGS_MON_STATEFILE} = $state;
    $ENV{ASGS_MON_RUNDIR} = $rundir;
    $ENV{ASGS_MON_SCRIPTDIR} = $scriptdir;
    $ENV{ASGS_MON_LASTSUBDIR} = $last;
    $ENV{MOCK_ATCF_FIXTURE} = $fixture;
    $ENV{MOCK_RSS_FIXTURE} = $rss;
    $ENV{MOCK_ADAPTER_ADV} = $opt{adapter_advisory} if defined $opt{adapter_advisory};
    delete @ENV{qw/TROPICALCYCLONE STORM YEAR TRIGGER RSSSITE FTPSITE FDIR HDIR GET_ATCF_SCRIPT/};

    my @before = sort glob("$rundir/*");
    my $result = run_sanity_check(probe_timeout => 5);
    my @after = sort glob("$rundir/*");
    return ($result, \@before, \@after, "$rundir/sentinel");
}

{
    my ($r, $before, $after, $sentinel) = make_case();
    is($r->{status}, q{OK}, q{healthy rebased/replay timeline is OK without wall-clock comparison});
    is($r->{source}->{product_advisory}, q{002A}, q{source preserves intermediate advisory});
    is($r->{source}->{adapter_advisory}, q{002}, q{adapter numeric result is recorded separately});
    like(join("\n", @{ $r->{notes} }), qr/precision is limited/i, q{suffix collapse is reported as a limitation, not invented away});
    is_deeply($after, $before, q{probe does not create files in active RUNDIR});
    open my $fh, q{<}, $sentinel or die $!; my $x=<$fh>; close $fh;
    is($x, "do not touch\n", q{active RUNDIR sentinel remains byte-for-byte unchanged});
}

{
    my ($r) = make_case(fixture => "$Bin/fixtures/atcf/al052026-zero.fst");
    is($r->{status}, q{CRITICAL}, q{forecast end equal to advisory/model start is CRITICAL});
    ok(grep($_->{id} eq q{forecast_end_not_after_advisory}, @{ $r->{issues} }), q{exact forecast-end-before/equal-start class identified});
}

{
    my ($r) = make_case(hstime => 2635200); # 30d + 12h: model clock 12h ahead of 2026090306
    is($r->{status}, q{CRITICAL}, q{stale/reused hotstart ahead of ATCF model time is CRITICAL});
    ok(grep($_->{id} eq q{hotstart_after_advisory}, @{ $r->{issues} }), q{hotstart timeline inconsistency is explicit});
}

{
    my ($r) = make_case(collapsed => 1);
    is($r->{status}, q{CRITICAL}, q{collapsed ASGS forecast is CRITICAL});
    ok(grep($_->{id} eq q{run_end_not_after_start}, @{ $r->{issues} }), q{RunEndTime <= RunStartTime detected});
    ok(grep($_->{id} eq q{rnday_2dt_guard}, @{ $r->{issues} }), q{2*dt safeguard precursor detected});
    ok(grep($_->{id} eq q{forecast_duration_tiny}, @{ $r->{issues} }), q{four-second remaining duration detected});
}

{
    my ($r) = make_case(
        fixture => "$Bin/fixtures/atcf/al052026-live003.fst",
        rss => "$Bin/fixtures/atcf/index-003.xml",
        adapter_advisory => q{03},
        state_advisory => q{003},
        live_duplicates => 1,
    );
    is($r->{status}, q{CRITICAL}, q{live-like collapsed advisory remains CRITICAL});
    is(sprintf(q{%.1f}, $r->{timeline}->{hotstart_to_advisory_hours}), q{12.0},
        q{hotstart-to-advisory advance is explicitly quantified});
    ok(grep($_->{id} eq q{hotstart_before_advisory} && $_->{severity} eq q{INFO}, @{ $r->{issues} }),
        q{normal hotstart-before-advisory relationship is explicitly informational});
    is($r->{source}->{adapter_advisory_raw}, q{03}, q{raw adapter advisory token is retained});
    is($r->{source}->{adapter_advisory}, q{003}, q{normalized adapter advisory is retained separately});
    is($r->{asgs}->{advisory_raw}, q{003}, q{raw ASGS state advisory is retained});
    ok(@{ $r->{scenarios} } > @{ $r->{scenario_summary} },
        q{human scenario summary deduplicates raw property observations});
    my @clock_groups = grep {
        defined($_->{adcirc_remaining_seconds})
        && abs($_->{adcirc_remaining_seconds} - 4) < 0.01
    } @{ $r->{scenario_summary} };
    is(scalar(@clock_groups), 1, q{identical four-second scenario clocks collapse to one display group});
    my @runend = grep { $_->{id} eq q{run_end_not_after_start} } @{ $r->{issues} };
    is(scalar(@runend), 1, q{repeated RunEndTime failure is one aggregated assessment});
    ok(grep($_ eq q{nowcast}, @{ $runend[0]->{scenarios} || [] }),
        q{aggregated assessment names affected scenarios});
    ok(@{ $r->{scenario_issues} } > 1,
        q{raw scenario issue evidence remains available in structured result});
}

{
    my $tmp = tempdir(CLEANUP => 1);
    my $cfg = "$tmp/off.sh";
    write_file($cfg, "TROPICALCYCLONE=off\n");
    local %ENV = %ENV;
    $ENV{ASGS_MON_CONFIG} = $cfg;
    delete $ENV{TROPICALCYCLONE};
    my $r = run_sanity_check(config => $cfg);
    is($r->{status}, q{OK}, q{non-TC profile is not an error});
    ok(!$r->{applicable}, q{non-TC profile marked not applicable});
}


{
    # Across a replay/operational sequence, a distinct next advisory must move
    # model time forward. History is monitor-owned temporary state, never ASGS state.
    my $tmp = tempdir(CLEANUP => 1);
    my $scriptdir = "$tmp/asgs";
    my $rundir = "$tmp/run";
    make_path("$scriptdir/bin", $rundir);
    my $adapter = "$scriptdir/bin/get_atcf_http.pl";
    write_file($adapter, <<'MOCKSEQ');
#!/usr/bin/env perl
use strict; use warnings;
use File::Copy qw/copy/;
my %o; while (@ARGV) { my $k=shift @ARGV; my $v=shift @ARGV; $k =~ s/^--//; $o{$k}=$v; }
copy($ENV{MOCK_ATCF_FIXTURE}, sprintf("al%02d%s.fst",$o{storm},$o{year})) or die $!;
copy($ENV{MOCK_RSS_FIXTURE}, "index-at.xml") or die $!;
print "01\n";
MOCKSEQ
    chmod 0755, $adapter;
    my $cfg = "$tmp/config.sh";
    write_file($cfg, qq{TROPICALCYCLONE=on\nSTORM=05\nYEAR=2026\nTRIGGER=rssembedded\nGET_ATCF_SCRIPT="\$SCRIPTDIR/bin/get_atcf_http.pl"\nRSSSITE=example\nFTPSITE=example\nFDIR=/f\nHDIR=/h\nCOLDSTARTDATE=2026080400\nHINDCASTLENGTH=30\n});
    my $state = "$tmp/state";
    write_file($state, "RUNDIR=$rundir\nSCRIPTDIR=$scriptdir\nADVISORY=001\nCYCLE=001\nCOLDSTARTDATE=2026080400\n");
    my $rss1 = "$tmp/001.xml";
    my $rss1a = "$tmp/001A.xml";
    write_file($rss1, "TROPICAL STORM EDOUARD FORECAST/ADVISORY NUMBER 1\nNWS NATIONAL HURRICANE CENTER MIAMI FL AL052026\n");
    write_file($rss1a, "TROPICAL STORM EDOUARD FORECAST/ADVISORY NUMBER 1A\nNWS NATIONAL HURRICANE CENTER MIAMI FL AL052026\n");

    local %ENV = %ENV;
    $ENV{ASGS_TMPDIR} = "$tmp/mon-tmp"; make_path($ENV{ASGS_TMPDIR});
    $ENV{ASGS_MON_CONFIG} = $cfg;
    $ENV{ASGS_MON_STATEFILE} = $state;
    $ENV{ASGS_MON_RUNDIR} = $rundir;
    $ENV{ASGS_MON_SCRIPTDIR} = $scriptdir;
    $ENV{MOCK_ATCF_FIXTURE} = "$Bin/fixtures/atcf/al052026-001.fst";
    $ENV{MOCK_RSS_FIXTURE} = $rss1;
    delete @ENV{qw/TROPICALCYCLONE STORM YEAR TRIGGER RSSSITE FTPSITE FDIR HDIR GET_ATCF_SCRIPT/};

    my $first = run_sanity_check(probe_timeout => 5);
    is($first->{status}, q{OK}, q{first advisory establishes relative-time history});
    $ENV{MOCK_RSS_FIXTURE} = $rss1a; # distinct advisory, same ATCF model timestamp
    my $second = run_sanity_check(probe_timeout => 5);
    is($second->{status}, q{CRITICAL}, q{next advisory with non-advancing model time is CRITICAL});
    ok(grep($_->{id} eq q{advisory_time_not_advancing}, @{ $second->{issues} }), q{cross-advisory model-time regression is identified});
}

done_testing;
