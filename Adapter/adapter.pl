# Loads NowPlayingAdapter.dylib inside Apple-signed /usr/bin/perl.
# Usage: /usr/bin/perl adapter.pl /path/to/NowPlayingAdapter.dylib stream|command
use strict;
use DynaLoader;

my ($lib, $mode) = @ARGV;
die "usage: adapter.pl <dylib> stream|command\n" unless $lib && $mode;
my $fn = $mode eq 'command' ? 'nis_command' : 'nis_stream';

my $handle = DynaLoader::dl_load_file($lib, 0) or die DynaLoader::dl_error();
my $sym = DynaLoader::dl_find_symbol($handle, $fn) or die DynaLoader::dl_error();
DynaLoader::dl_install_xsub("main::$fn", $sym);
no strict 'refs';
&{"main::$fn"}();
