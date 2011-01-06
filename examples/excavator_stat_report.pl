#!/usr/bin/perl
#
# Process mail archive and pull out excavator stats

use strict;
use warnings;

use feature ':5.10';

use FindBin;
use Getopt::Long;
use Data::Dumper;
use DBI;
use POSIX qw(ceil);

use lib "$FindBin::Bin/../lib";

my %opts;
GetOptions(\%opts,
    'h|help',
    'db=s',
);

usage() if $opts{h};

my $db_file = $opts{db} || "$FindBin::Bin/../excavators.db";
my $dbh = DBI->connect("DBI:SQLite:dbname=$db_file",'','');

# display stats
# total excavators
my ($total, $dist) = $dbh->selectrow_array('select count(*) as count, avg(distance) as avg from trip', undef);
output(sprintf("%d excavators sent an average of %.2f units.\n\n", $total, $dist));
# breakdown by type
{
    output("Broken down by type:\n");
    my $sth = $dbh->prepare('select found, count(*) as count from trip group by 1 order by 2 desc');
    $sth->execute();
    while (my ($found, $count) = $sth->fetchrow_array) {
        output(sprintf("%s: %d\n", $found, $count));
    }
    output("\n");
}
# list number of each type of plan found
{
    output("Plans found:\n");
    my $sth = $dbh->prepare("select type || ' ' || amount, count(*) as count from trip where found = ? group by 1 order by 1,2 desc");
    $sth->execute('plan');
    while (my ($plan, $count) = $sth->fetchrow_array) {
        output(sprintf("  %s: %d\n", $plan, $count));
    }
    output("\n");
}
# every 250, show % empty, resource, glyph, plan
{
    output("Finds by distance:\n");
    my ($max_distance) = $dbh->selectrow_array('select max(0+distance) from trip', undef);
    output("  Distance   |     Empty   |  Resources  |    Glyphs   |     Plans   |   Total\n");
    output("------------------------------------------------------------------------------\n");
    for (my $i = 0; $i <= $max_distance; $i += 250) {
        # total for this distance
        my ($total) = $dbh->selectrow_array('select count(*) as count from trip where 0+distance >= 0+? and 0+distance < 0+?', undef, $i, $i + 250);
        next unless $total;
        # breakdown for this distance
        my $breakdown = $dbh->selectall_hashref('select found, count(*) as count from trip where 0+distance >= 0+? and 0+distance < 0+? group by 1 order by 2 desc', 'found', undef, $i, $i + 250);
        output(sprintf("   %4s-%4s |", $i, $i + 250));
        output(sprintf("%7s/%3.0f%% |", $breakdown->{nothing}{count} || 0, 100 * (($breakdown->{nothing}{count}  || 0)/ $total)));
        output(sprintf("%7s/%3.0f%% |", $breakdown->{resource}{count} || 0, 100 * (($breakdown->{resource}{count}  || 0)/ $total)));
        output(sprintf("%7s/%3.0f%% |", $breakdown->{glyph}{count} || 0, 100 * (($breakdown->{glyph}{count}  || 0)/ $total)));
        output(sprintf("%7s/%3.0f%% |", $breakdown->{plan}{count} || 0, 100 * (($breakdown->{plan}{count}  || 0)/ $total)));
        output(sprintf("%8s", $total));
        output("\n");
    }
    output("\n");
}
sub verbose {
    return unless $opts{v};
    print @_;
}

sub output {
    return if $opts{q};
    print @_;
}

sub usage {
    print STDERR <<END;
Usage: $0 [options]

This simply outputs the data from your excavator database, combined for all empires.
It does not use the API.

Options:

  --verbose       - Print more output
  --quiet         - Only output errors
  --db     <file> - SQLite db containing your excavation history
END

    exit 1;
}
