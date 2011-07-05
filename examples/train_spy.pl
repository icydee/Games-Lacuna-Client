#!/usr/bin/perl

use strict;
use warnings;
use Getopt::Long          qw(GetOptions);
use List::Util            qw( first );
use FindBin;
use lib "$FindBin::Bin/../lib";
use Games::Lacuna::Client ();

my $planet_name;
my $assignment;

GetOptions(
    'planet=s'     => \$planet_name,
    'training=s'   => \$assignment,
);

usage() if !$planet_name || !$assignment;

my %trainhash = (
    theft     => 'TheftTraining',
    intel     => 'IntelTraining',
    politics  => 'PoliticsTraining',
    mayhem    => 'MayhemTraining',
);

unless ( first { $_ eq $assignment } keys %trainhash ) {
    die("Must specify one of the following training types:\n\n", join("\n", keys %trainhash), "\n");
}

my $cfg_file = shift(@ARGV) || 'lacuna.yml';
unless ( $cfg_file and -e $cfg_file ) {
  $cfg_file = eval{
    require File::HomeDir;
    require File::Spec;
    my $dist = File::HomeDir->my_dist_config('Games-Lacuna-Client');
    File::Spec->catfile(
      $dist,
      'login.yml'
    ) if $dist;
  };
  unless ( $cfg_file and -e $cfg_file ) {
    die "Did not provide a config file";
  }
}

my $client = Games::Lacuna::Client->new(
	cfg_file => $cfg_file,
	prompt_captcha => 1,
	# debug    => 1,
);

# Load the planets
my $empire  = $client->empire->get_status->{empire};

# reverse hash, to key by name instead of id
my %planets = reverse %{ $empire->{planets} };

my $body      = $client->body( id => $planets{$planet_name} );
my $buildings = $body->get_buildings->{buildings};

my $intel_id = first {
        $buildings->{$_}->{url} eq '/intelligence'
} keys %$buildings;

my $intel = $client->building( id => $intel_id, type => 'Intelligence' );
my @spies;

my $building_id = first {
    $buildings->{$_}->{url} eq "/${assignment}training"
} keys %$buildings;

unless ( $building_id ) {
    die("No $assignment training facility found on $planet_name.")
}

my $building = $client->building( id => $building_id, type => $trainhash{ $assignment } );

SPY:
for my $spy ( @{ $intel->view_spies->{spies} } ) {

    next SPY unless $spy->{assignment} eq 'Idle';

    my $return;
    eval {
        $return = $building->train_spy( $spy->{ id } );
    };

    if ($@) {
        warn "Error: $@\n";
        next;
    }

    print( $return->{trained} ? "Spy trained\n" : "Spy not trained\n" );
}

exit;


sub usage {
  die <<"END_USAGE";
Usage: $0 CONFIG_FILE
    --planet   PLANET
    --training TYPE

CONFIG_FILE  defaults to 'lacuna.yml'

--planet is the planet that your spy is from.

--training must match one of the following: intel, mayhem, theft, politics

END_USAGE

}
