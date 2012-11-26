use strict;
use warnings;
use File::HomeDir::Test;
use File::Temp qw( tempdir );
use File::Spec;
use File::Touch qw( touch );
use Test::PlugAuth::Plugin::Auth;

my $tempdir = tempdir( CLEANUP => 1);

my $user_file = File::Spec->catfile($tempdir, "user.txt");
touch $user_file;

run_tests 'FlatAuth', { 
  user_file => $user_file,
  group_file => do {
    my $fn = File::Spec->catfile($tempdir, "group.txt");
    touch $fn;
    $fn;
  },
};
