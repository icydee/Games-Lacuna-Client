#!/usr/bin/perl

use strict;
use warnings;
use 5.010;
use List::Util            (qw(first));
use Games::Lacuna::Client ();
use Getopt::Long          (qw(GetOptions));
use DateTime;
use Try::Tiny;
use YAML::Any             (qw(Dump));
my $star;
my $orbit;
my $eta;
my $outfile;

our $LocalTZ = DateTime::TimeZone->new( name => 'local' )->name;

GetOptions(
    'star=s'    => \$star,
    'orbit=s'   => \$orbit,
    'eta=s'     => \$eta,
    'outfile=s' => \$outfile,
);

usage() if !$star || !$orbit || !$eta;

my $t1;
my $tminus;
local_scope: {
    my %eta;
    @eta{qw(year month day hour minute second time_zone)} = (split(/:/, $eta),'UTC');
    $t1 = DateTime->new(%eta);
    my $t0 = DateTime->now(time_zone => 'UTC');
    my $seconds_dur = $t1->subtract_datetime_absolute($t0);
    $tminus = $seconds_dur->seconds();
    say 'T minus: ', $tminus, ' seconds';
}

my $cfg_file = shift(@ARGV) || 'lacuna.yml';
unless ( $cfg_file and -e $cfg_file ) {
    die "Did not provide a config file";
}

my $client = Games::Lacuna::Client->new(
        cfg_file => $cfg_file,
         #debug    => 1,
);

my $empire  = $client->empire->get_status->{empire};
my $planets = $empire->{planets};
my %target;
my %bol;      #Bill of Lading

my $star_result = $client->map->get_star_by_name($star)->{star};

# find planet in $orbit around $star
my ($target_body) = grep {$_->{orbit} == $orbit} @{$star_result->{bodies}};
die "Planet not found in orbit $orbit of star '$star'"
    if !$target_body;

$target{id}   = $target_body->{id};
$target{name} = "$target_body->{name} [$star]";
$target{type} = 'body_id';
$target{x}    = $target_body->{x};
$target{y}    = $target_body->{y};

for my $from_id (sort { $planets->{$a} cmp $planets->{$b} } keys %$planets) {
    my %poo; # point of origin

    # find planet, buildings on that planet, and finally its spaceport
    my $body   = $client->body( id => $from_id );
    my $result = $body->get_buildings;
    @poo{qw(name id x y w1 w2)} = (@{$result->{status}{body}}{qw(name id x y)}); #,{}{});
    my $planet_id = $poo{id};
    $poo{d} = sqrt(abs($target{x}-$poo{x})**2 + abs($target{y}-$poo{y})); # distance to target from point of origin

#    say "From " . $planets->{$from_id} . sprintf(" (distance: %.3f):",$poo{d});

    my $buildings    = $result->{buildings};
    my $space_port_id = first {
            $buildings->{$_}->{name} eq 'Space Port'
    } keys %$buildings;
    my $space_port = $client->building( id => $space_port_id, type => 'SpacePort' );

    # get the ships we can send from that spaceport to our target
    my $ships = $space_port->get_ships_for( $from_id, { body_id => $target{id} } );
    my $available = $ships->{available};

    # Scanners and Sweepers go into Wave 1, everything else into Wave 2
    for my $ship (sort { $a->{name} cmp $b->{name} } @$available) {
        my ($ship_id, $name, $type, $speed) = @{$ship}{qw(id name type speed)};

        my $secs = ($poo{d} / ($speed/100)) * 60 * 60; # duration in seconds
        my $wave=1;
        given ($ship->{type}) {
            when ('scanner') {
                # first wave
            }
            when ('sweeper') {
                # first wave trailing scanners

                $secs -= 20;
            }
            default {
                $secs -= 60;
                $wave=2;
            }
        }

        my %order;
        @order{qw(planet_id planet_name ship_id ship_name ship_type ship_speed)} = (@poo{qw(id name)}, $ship_id, $name, $type, $speed);
        my $d = DateTime::Duration->new(seconds => $secs);
        my $launch = $t1->clone->subtract($d)->strftime('%F %T');
        my $launch_local = $t1->clone->subtract($d)->set_time_zone($LocalTZ)->strftime('%F %T');

        $launch = "$launch ($launch_local $LocalTZ)";
        if ($secs < $tminus) { # if ship can arrive by eta add to a wave of attack
            $bol{$launch} ||= [];
            $order{wave}=$wave;
            push @{$bol{$launch}}, \%order;
        }
    }
}

print "Launch Plan $target{name}:\n";
for my $launch (sort keys %bol) {
    print "\t$launch\n";
    for my $o (@{$bol{$launch}}) {
        print "\t\t$o->{planet_name}, $o->{ship_name}, $o->{ship_type}, $o->{ship_speed}, wave $o->{wave}\n";
    }
}

if ($outfile) {
    open my $out, '>', $outfile or die $1;
    my $plan = { target => \%target,
                 eta    => $t1->set_time_zone('UTC')->strftime('%F %T') . ' UTC',
                 armada => \%bol };
    print $out Dump($plan);
}



sub usage {
  die <<"END_USAGE";
Usage: $0 attack_schedule.yml
       --star       NAME   (required)
       --orbit      NUMBER (required)
       --eta        TIME   (required)
       --outfile    FILENAME (optional)

Lays out the attack times to the target planet.

The eta is the time at which the 1st wave should arrive.
eta must be provided in the following format: yyyy:MM:dd:HH:mm::ss
Timezone is assumed to be UTC.

If --outfile is provided, it will create a YAML file which can be
edited and used as input to a launch script.

END_USAGE

}



