#!/usr/bin/env perl

use strict;
use warnings;

my $logconf = "
############################################################
# A simple root logger with a Log::Log4perl::Appender::File
# file appender in Perl.
############################################################
log4perl.rootLogger=DEBUG, LOGFILE, Screen

log4perl.appender.LOGFILE=Log::Log4perl::Appender::File
log4perl.appender.LOGFILE.filename=run.log
log4perl.appender.LOGFILE.mode=append

log4perl.appender.LOGFILE.layout=PatternLayout
log4perl.appender.LOGFILE.layout.ConversionPattern=[%r] %F %L %c - %m%n

log4perl.appender.Screen         = Log::Log4perl::Appender::Screen
log4perl.appender.Screen.stderr  = 0
log4perl.appender.Screen.layout = PatternLayout
log4perl.appender.Screen.layout.ConversionPattern=[%d] %c - %m%n
";

use File::Temp;
use File::Copy;
use IPC::System::Simple qw(capturex);

use Log::Log4perl;
Log::Log4perl->init(\$logconf);

my $logger = Log::Log4perl->get_logger();

# create a 1 GB random drive as seed
$logger->info("Starting to create a random file...");
my $temp_file = "/tmp/random_1Gb.bin";
if (-e $temp_file)
{
    $logger->info("File already exists... Skipping its creation!");
} else {
    system("dd if=/dev/urandom of=/tmp/random_1Gb.bin bs=1M count=1024");
}
my $temp_file_size = -s $temp_file;
$logger->info(sprintf("Finished to creation of the random file '%s' with size %d Bytes", $temp_file, $temp_file_size));

my @compression_levels=qw(lz4 off);
my @recordsizes=qw(128k 1M);

my @min_filled = (0, 0.25, 0.5, 0.75, 0.9);

my %settings=(
    single_drive => "sda",
    mirror_same_shelf => "mirror sda sdb",
    mirror_different_shelfs => "mirror sda sdg",
    raidz_same_shelf => "raidz sda sdb sdc sdd sde sdf",
    raidz_different_shelfs => "raidz sda sdb sdc sdg sdh sdi",
    two_raidz_different_shelfs => "raidz sda sdb sdc sdd sde sdf raidz sdg sdh sdi sdj sdk sdl",
    raidz2_same_shelf => "raidz2 sda sdb sdc sdd sde sdf",
    raidz2_different_shelfs => "raidz2 sda sdb sdc sdg sdh sdi",
    two_raidz2_different_shelfs => "raidz2 sda sdb sdc sdd sde sdf raidz2 sdg sdh sdi sdj sdk sdl"
);

my $outfile = "run.out";
open(OUTPUT, ">", $outfile) || die "Unable to open '$outfile' for writing!";

foreach my $setting (keys %settings)
{
    foreach my $recordsize (@recordsizes)
    {
	foreach my $compression (@compression_levels)
	{
	    my $outfile = join("-", ("bonnie", $setting, $recordsize, $compression));

	    $logger->info(sprintf("Starting a test with vdev settings '%s', recordsize: %s and compression %s...", $setting, $recordsize, $compression));
	    do_zfs_benchmark($outfile, $recordsize, $settings{$setting}, $compression);
	    $logger->info("Finished test");
	}
    }
}

close(OUTPUT) || die "Unable to close '$outfile' after writing!";

sub do_zfs_benchmark
{
    my ($testbasename, $recordsize, $diskconfig, $compression) = @_;

    $logger->info("Creating a new zpool...");
    my $cmd = "zpool";
    my @args = ("create", "-o", "ashift=12", "-o", "autoexpand=on", "tank", split(/\s+/, $diskconfig));
    system($cmd, @args) == 0 or die "Error creating the pool: $?";
    $logger->info("Finished creation of a new zpool");

    $logger->info("Exporting tank...");
    $cmd = "zpool";
    @args = ("export", "tank");
    system($cmd, @args) == 0 or die "Error on exporting of the pool: $?";
    $logger->info("Finished export of tank");

    $logger->info("Re-importing tank...");
    $cmd = "zpool";
    @args = ("import", "-d", "/dev/disk/by-path/", "tank");
    system($cmd, @args) == 0 or die "Error on reimport of the pool: $?";
    $logger->info("Finished re-import of tank");

    $logger->info("Setting compression of tank...");
    $cmd = "zfs";
    @args = ("set", "compression=$compression", "tank");
    system($cmd, @args) == 0 or die "Error while setting the compression to '$compression': $?";
    $logger->info("Finished compression setting");

    $logger->info("Setting recordsize of tank...");
    $cmd = "zfs";
    @args = ("set", "recordsize=$recordsize", "tank");
    system($cmd, @args) == 0 or die "Error while setting the recordsize to '$recordsize': $?";
    $logger->info("Finished recordsize setting");

    $logger->info("Creating temporary folder...");
    mkdir("/tank/test") || die "Error on creating the folder: $?";
    chmod 0777, "/tank/test" || die "Error on changing folder permission: $?";
    $logger->info("Finished creation of temporary folder");

    foreach my $fillstatus (@min_filled)
    {
	$logger->info(sprintf("Filling tank to at least %.2f%% of its capacity", $fillstatus*100));
	my $filllevel = fill_tank_to_at_least($fillstatus);
	$logger->info(sprintf("Finished filling tank. Filllevel is now at %.2f%% of its capacity.", $filllevel*100));

	$logger->info("Running bonnie++ benchmark...");
	$cmd = "bonnie++";
	my $testname = sprintf("%s-%07.3f_percent_filled", $testbasename, $filllevel);
	@args = ("-m", $testname, "-d", "/tank/test", "-u", "genomics", "-n", "192", "-q");
	my $output = capturex($cmd, @args);

	print OUTPUT $output;

	$logger->info("Finished bonnie++ benchmark run");
    }

    $logger->info("Destroying tank...");
    $cmd = "zpool";
    @args = ("destroy", "tank");
    system($cmd, @args) == 0 or die "Error on destroy of the pool: $?";
    $logger->info("Finished destruction of tank...");
}

sub fill_tank_to_at_least
{
    my ($requested_filllevel) = @_;

    my $curr_fill = get_fill_level();

    $logger->info(sprintf("Current fill level of tank is %f%%...", $curr_fill*100));

    while ($curr_fill < $requested_filllevel)
    {
	my $required_to_fill = $requested_filllevel - $curr_fill;
	my $space_to_fill = get_zpool_size()*$required_to_fill;

	my $files2create = int($space_to_fill/$temp_file_size)+1;

	for(my $i=0; $i<$files2create; $i++)
	{
	    # create a new filename
	    my $unopened_file = File::Temp::tempnam( "/tank/temp/", "temp".("X"x20) );
	    # and copy the content of the temp file to it
	    copy($temp_file, $unopened_file) || die "Copy failed: $!";
	}

	$curr_fill = get_fill_level();
    }

    $logger->info(sprintf("Current fill level of tank is %f%%...", $curr_fill*100));

    return $curr_fill;
}

sub get_zpool_size
{
    my $cmd = "zpool";
    my @args = split(/\s+/, "list -o capacity,expandsize,fragmentation,free,freeing,health,size,ashift,allocated,comment,version -H tank");
    my $output = capturex($cmd, @args);
    chomp($output);

    my ($capacity, $expandsize, $fragmentation, $free, $freeing, $health, $size, $ashift, $allocated, $comment, $version) = split(/\t/, $output);

    $size = convert_to_real_number($size);

    return $size;
}

sub get_fill_level
{
    my $cmd = "zpool";
    my @args = split(/\s+/, "list -o capacity,expandsize,fragmentation,free,freeing,health,size,ashift,allocated,comment,version -H tank");
    my $output = capturex($cmd, @args);
    chomp($output);

    my ($capacity, $expandsize, $fragmentation, $free, $freeing, $health, $size, $ashift, $allocated, $comment, $version) = split(/\t/, $output);

    # convert the suffixes into real numbers
    $allocated = convert_to_real_number($allocated);
    $size = get_zpool_size();

    return $allocated/$size;
}

sub convert_to_real_number
{
    my ($input) = @_;

    # if comma are present, replace them by .
    $input =~ s/,/./g;

    # convert the suffixes into real numbers
    if ($input =~ s/(\D)$//)
    {
	my $factor = 1;
	if ($1 eq "T")
	{
	    $factor = 2**40;
	} elsif ($1 eq "G")
	{
	    $factor = 2**30;
	} elsif ($1 eq "M")
	{
	    $factor = 2**20;
	} elsif ($1 eq "K")
	{
	    $factor = 2**10;
	}

	$input = $input*$factor;
    }

    return $input;
}
