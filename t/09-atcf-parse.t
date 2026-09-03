use v5.12;
use strict;
use warnings;
use Test::More;
use FindBin qw/$Bin/;
use lib "$Bin/../lib";
use ASGS::Mon::ATCF qw/parse_atcf_file parse_source_product normalize_advisory ymdh_to_epoch epoch_to_ymdh/;

my $healthy = "$Bin/fixtures/atcf/al052026-healthy.fst";
my $a = parse_atcf_file($healthy);
is_deeply($a->{errors}, [], q{healthy fixed-column ATCF parses cleanly});
is($a->{storm}, q{05}, q{storm number parsed});
is($a->{name}, q{EDOUARD}, q{storm name parsed});
is($a->{model_time}, q{2026090306}, q{advisory/model time parsed});
is($a->{forecast_end_time}, q{2026090503}, q{forecast end uses maximum OFCL tau});
is($a->{forecast_hours}, 45, q{forecast lead preserved});

my $xml;
{
    open my $fh, q{<}, "$Bin/fixtures/atcf/index-002A.xml" or die $!;
    local $/;
    $xml = <$fh>;
    close $fh;
}
my $products = parse_source_product($xml, q{05}, q{2026});
is(scalar(@$products), 1, q{Forecast/Advisory product found in RSS snapshot});
is($products->[0]->{advisory}, q{002A}, q{intermediate advisory suffix is preserved});
ok($products->[0]->{matches_config}, q{RSS storm/year matches configured storm});
is(normalize_advisory(q{2a}), q{002A}, q{advisory normalization does not collapse suffix});

my $epoch = ymdh_to_epoch(q{2026090306});
ok(defined $epoch, q{valid UTC model time converts to epoch});
is(epoch_to_ymdh($epoch), q{2026090306}, q{UTC conversion round trips});

my $zero = parse_atcf_file("$Bin/fixtures/atcf/al052026-zero.fst");
is($zero->{forecast_end_time}, q{2026090306}, q{zero-lead fixture demonstrates forecast end == advisory time});

done_testing;
