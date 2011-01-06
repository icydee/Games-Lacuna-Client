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
use Games::Lacuna::Client;

my %opts;
GetOptions(\%opts,
    'h|help',
    'v|verbose',
    'q|quiet',
    'config=s',
    'db=s',
    'bootstrap',
);

usage() if $opts{h};

my $glc = Games::Lacuna::Client->new(
    cfg_file => $opts{config} || "$FindBin::Bin/../lacuna.yml",
);

my $db_file = $opts{db} || "$FindBin::Bin/../excavators.db";
my $dbh = DBI->connect("DBI:SQLite:dbname=$db_file",'','');


my $empire = $glc->empire->get_status->{empire};

bootstrap($empire->{id}) if $opts{bootstrap};

# look for max id
my $max_id = eval {
    get_max_id($empire->{id});
};
if ($@) {
    output("Failed reading database ... does it exist and has it been bootstrapped?");
    exit;
}

my $new_max_id = 0;
my $message_count = $glc->inbox->view_archived()->{message_count};
my $pages = ceil($message_count / 25);
PAGE: for my $page (1..$pages) {
    # look back through archive where newer than max id
    verbose("Grabbing page $page from the archive\n");
    my $messages = $glc->inbox->view_archived({page_number => $page})->{messages};
    last unless scalar @$messages;
    for my $msg (@$messages) {
        if ($msg->{id} <= $max_id) {
            output("Done processing new messages.\n\n");
            $new_max_id = $new_max_id > $max_id ? $new_max_id : $max_id;
            last PAGE;
        }
        # grab each excavator message and save excavator results
        given ($msg->{subject}) {
            when ('Glyph Discovered!') { parse_glyph_message($glc->inbox->read_message($msg->{id})->{message}) }
            when ('Resources Discovered!') { parse_resource_message($glc->inbox->read_message($msg->{id})->{message}) }
            when ('Excavator Uncovered Plan') { parse_plan_message($glc->inbox->read_message($msg->{id})->{message}) }
            when ('Excavator Found Nothing') { parse_nothing_message($glc->inbox->read_message($msg->{id})->{message}) }
        }
        $new_max_id = $msg->{id} if ($msg->{id} > $new_max_id);
    }
}

$dbh->do('UPDATE processed SET message_id = ? where empire_id = ?', undef, $new_max_id, $empire->{id});

# display stats
# total excavators
my ($total, $dist) = $dbh->selectrow_array('select count(*) as count, avg(distance) as avg from trip where empire_id = ?', undef, $empire->{id});
output(sprintf("%d excavators sent an average of %.2f units.\n\n", $total, $dist));
# breakdown by type
{
    output("Broken down by type:\n");
    my $sth = $dbh->prepare('select found, count(*) as count from trip where empire_id = ? group by 1 order by 2 desc');
    $sth->execute($empire->{id});
    while (my ($found, $count) = $sth->fetchrow_array) {
        output(sprintf("%s: %d\n", $found, $count));
    }
    output("\n");
}
# list number of each type of glyph found
{
    output("Glyphs excavated:\n");
    my $sth = $dbh->prepare('select type, count(*) as count from trip where empire_id = ? and found = ? group by 1 order by 2 desc');
    $sth->execute($empire->{id}, 'glyph');
    my $cnt;
    while (my ($glyph, $count) = $sth->fetchrow_array) {
        output(sprintf '%13s: %d', $glyph, $count);
        output("\n") unless ++$cnt % 4
    }
    output("\n") if $cnt % 4;
    output("\n");
}
# list number of each type of plan found
{
    output("Plans found:\n");
    my $sth = $dbh->prepare("select type || ' ' || amount, count(*) as count from trip where empire_id = ? and found = ? group by 1 order by 1,2 desc");
    $sth->execute($empire->{id}, 'plan');
    while (my ($plan, $count) = $sth->fetchrow_array) {
        output(sprintf("  %s: %d\n", $plan, $count));
    }
    output("\n");
}
# resources
{
    output("Resources found:\n");
    my $sth = $dbh->prepare('select sum(amount), type, count(*) as count from trip where empire_id = ? and found = ? group by 2 order by 1 desc');
    $sth->execute($empire->{id}, 'resource');
    my $cnt;
    while (my ($total, $type, $count) = $sth->fetchrow_array) {
        output(sprintf("%10d %13s (%d)\n", $total, $type, $count));
    }
    output("\n");
}
# every 250, show % empty, resource, glyph, plan
{
    output("Finds by distance:\n");
    my ($max_distance) = $dbh->selectrow_array('select max(0+distance) from trip where empire_id = ?', undef, $empire->{id});
    output("  Distance   |     Empty   |  Resources  |    Glyphs   |     Plans   |   Total\n");
    output("------------------------------------------------------------------------------\n");
    for (my $i = 0; $i <= $max_distance; $i += 250) {
        # total for this distance
        my ($total) = $dbh->selectrow_array('select count(*) as count from trip where empire_id = ? and distance >= ? and distance < ?', undef, $empire->{id}, $i, $i + 250);
        next unless $total;
        # breakdown for this distance
        my $breakdown = $dbh->selectall_hashref('select found, count(*) as count from trip where empire_id = ? and distance >= ? and distance < ? group by 1 order by 2 desc', 'found', undef, $empire->{id}, $i, $i + 250);
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

# display api use counts
output("$glc->{total_calls} api calls made.\n");

sub get_max_id {
    my ($empire_id) = @_;
    my $sql = "select message_id from processed where empire_id = ?";
    my ($max_id) = $dbh->selectrow_array($sql, undef, $empire_id);
    return $max_id;
}

sub bootstrap {
    my ($empire_id) = @_;
    output('Bootstrapping tables');
    $dbh->do('CREATE TABLE processed (message_id int, empire_id int)');
    $dbh->do('CREATE UNIQUE INDEX proc_uniq ON processed(message_id, empire_id)');
    $dbh->do('CREATE TABLE trip (empire_id int, message_id, subject text, found text, amount int, type text, from_x int, from_y int, from_name text, to_x int, to_y int, to_name text, distance text)');
    $dbh->do('CREATE UNIQUE INDEX trip_message ON trip(message_id, empire_id)');
    $dbh->do("INSERT INTO processed VALUES (0, $empire_id)");
}

sub parse_glyph_message {
    my ($message) = @_;
    # read email and toss out ArchMin emails
    return unless $message->{body} =~ /excavator/si;
    verbose("found a glyph, did you?\n");
    # get glyph type
    if ($message->{body} =~ /sent to {Starmap (-?\d+) (-?\d+) (.+?)}.*made entirely of (\w+).*back to {Planet (\w+) (.+?)}/s) {
        my ($to_x, $to_y, $to_name, $type, $planet_id, $from_name) = ($1, $2, $3, $4, $5, $6);
        verbose("Type: $type\n");
        verbose("to: ($to_x, $to_y) $to_name\n");
        verbose("from: ($planet_id) $from_name\n");
        my $body = get_from($planet_id);
        save_trip($empire->{id}, $message->{id}, $message->{subject}, 'glyph', 1, $type, $body->{body}{x}, $body->{body}{y}, $from_name, $to_x, $to_y, $to_name, euclid_dist($body->{body}{x}, $body->{body}{y}, $to_x, $to_y));
    }
    else {
        warn "Failed processing 'glyph' excavator message";
        verbose("$message->{body}\n");
    }
}

sub parse_resource_message {
    my ($message) = @_;
    # get resource type
    verbose("some resources, alas.\n");
    if ($message->{body} =~ /sent to {Starmap (-?\d+) (-?\d+) (.+?)}.*it did find (\d+) (\w+)\..*back to {Planet (\w+) (.+?)}/s) {
        my ($to_x, $to_y, $to_name, $amount, $type, $planet_id, $from_name) = ($1, $2, $3, $4, $5, $6, $7);
        verbose("Type: $amount $type\n");
        verbose("to: ($to_x, $to_y) $to_name\n");
        verbose("from: ($planet_id) $from_name\n");
        # get coords from planet
        my $body = get_from($planet_id);
        save_trip($empire->{id}, $message->{id}, $message->{subject}, 'resource', $amount, $type, $body->{body}{x}, $body->{body}{y}, $from_name, $to_x, $to_y, $to_name, euclid_dist($body->{body}{x}, $body->{body}{y}, $to_x, $to_y));
    }
    else {
        warn "Failed processing 'resource' excavator message";
        verbose("$message->{body}\n");
    }
}

sub parse_plan_message {
    my ($message) = @_;
    verbose("awesome, a plan\n");
    # get plan type
    if ($message->{body} =~ /While searching {Starmap (-?\d+) (-?\d+) (.+?)}.*build a level (\d+) (.+?)\..*back to {Planet (\w+) (.+?)}/s) {
        my ($to_x, $to_y, $to_name, $amount, $type, $planet_id, $from_name) = ($1, $2, $3, $4, $5, $6, $7);
        verbose("Level $amount $type\n");
        verbose("to: ($to_x, $to_y) $to_name\n");
        verbose("from: ($planet_id) $from_name\n");
        # get coords from planet
        my $body = get_from($planet_id);
        save_trip($empire->{id}, $message->{id}, $message->{subject}, 'plan', $amount, $type, $body->{body}{x}, $body->{body}{y}, $from_name, $to_x, $to_y, $to_name, euclid_dist($body->{body}{x}, $body->{body}{y}, $to_x, $to_y));
    }
    else {
        warn "Failed processing 'plan' excavator message";
        verbose("$message->{body}\n");
    }
}

sub parse_nothing_message {
    my ($message) = @_;
    verbose("bummer, empty excavator\n");
    # get coordinates
    if ($message->{body} =~ /sent to {Starmap (-?\d+) (-?\d+) (.+?)} from {Planet (\w+) (.+?)}/s) {
        my ($to_x, $to_y, $to_name, $planet_id, $from_name) = ($1, $2, $3, $4, $5);
        verbose("to: ($to_x, $to_y) $to_name\n");
        verbose("from: ($planet_id) $from_name\n");
        # get coords from planet
        my $body = get_from($planet_id);
        # calc distance
        save_trip($empire->{id}, $message->{id}, $message->{subject}, 'nothing', 0, undef, $body->{body}{x}, $body->{body}{y}, $from_name, $to_x, $to_y, $to_name, euclid_dist($body->{body}{x}, $body->{body}{y}, $to_x, $to_y));
    }
    else {
        warn "Failed processing 'nothing found' excavator message";
        verbose("$message->{body}\n");
    }
}

sub save_trip {
    my $sql = 'INSERT INTO trip (empire_id, message_id, subject, found, amount, type, from_x, from_y, from_name, to_x, to_y, to_name, distance) VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?)';
    $dbh->do($sql, undef, @_);
}

{
    my %cache;
    sub get_from {
        my ($planet_id) = @_;
        if ($cache{$planet_id}) {
            return $cache{$planet_id};
        }
        else {
            my $body = $glc->body(id => $planet_id)->get_status();
            $cache{$planet_id} = $glc->body(id => $planet_id)->get_status();
            return $cache{$planet_id};
        }
    }
}

sub euclid_dist {
    my ($x1, $y1, $x2, $y2) = @_;
    return sqrt(($x1-$x2)**2+($y1-$y2)**2);
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

This will process your email archive (not Inbox!) and save all excavator
trip data for stat calculation. It will save everything in a SQLite db
so it doesn't have to look it up again.

Options:

  --verbose       - Print more output
  --quiet         - Only output errors
  --config <file> - GLC config, defaults to lacuna.yml
  --db     <file> - SQLite db containing your excavation history
  --bootstrap     - Assume SQLite is empty and bootstrap it, will start you from scratch
END

    exit 1;
}
