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
log4perl.appender.LOGFILE.filename=/var/log/myerrs.log
log4perl.appender.LOGFILE.mode=append

log4perl.appender.LOGFILE.layout=PatternLayout
log4perl.appender.LOGFILE.layout.ConversionPattern=[%r] %F %L %c - %m%n

log4perl.appender.Screen         = Log::Log4perl::Appender::Screen
log4perl.appender.Screen.stderr  = 0
log4perl.appender.Screen.layout = PatternLayout
log4perl.appender.Screen.layout.ConversionPattern=[%d] %c - %m%n
";

use Log::Log4perl;
Log::Log4perl->init(\$logconf);

my $logger = Log::Log4perl->get_logger();

# create a 1 GB random drive as seed
$logger->info("Starting to create a random file...");
system("dd if=/dev/urandom of=/tmp/random_1Gb.bin bs=1M count=1024");
$logger->info("Finished to creation of the random file");

my @compression_levels=qw(lz4 gzip off);
my @recordsizes=qw(128k 512k 1M 2M 5M);

my %settings=(
    single_drive => "sda",
    mirror_same_shelf => "mirror sda sdb",
    mirror_different_shelfs => "mirror sda adg",
    raidz_same_shelf => "raidz sda sdb sdc sdd sde sdf",
    raidz_different_shelfs => "raidz sda sdb sdc sdg sdh sdi",
    two_raidz_different_shelfs => "raidz sda sdb sdc sdd sde sdf raidz sdg sdh sdi sdj sdk sdl",
    raidz2_same_shelf => "raidz2 sda sdb sdc sdd sde sdf",
    raidz2_different_shelfs => "raidz2 sda sdb sdc sdg sdh sdi",
    two_raidz2_different_shelfs => "raidz2 sda sdb sdc sdd sde sdf raidz sdg sdh sdi sdj sdk sdl"
);

foreach my $setting (keys %settings)
{
    foreach my $recordsize (@recordsizes)
    {
	foreach my $compression (@compression_levels)
	{
	    my $outfile = join("-", ("bonnie", $setting, $recordsize, $compression, "empty"));

	    do_zfs_benchmark($outfile, $recordsize, $settings{$setting}, $compression);
	}
    }
}

sub do_zfs_benchmark
{
    my ($outputfile, $recordsize, $diskconfig, $compression) = @_;

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

    $logger->info("Running bonnie++ benchmark...");
    $cmd = "bonnie++";
    @args = ("-m", $outputfile, "-d", "/tank/test", "-u", "genomics", "-n", "192", "-q", ">>", $outputfile.".csv");
    $cmd = join(" ", ($cmd, @args));
    system($cmd) == 0 or die "Error on running bonnie++ using the command '$cmd': $?";
    $logger->info("Finished bonnie++ benchmark run");

    $logger->info("Destroying tank...");
    $cmd = "zpool";
    @args = ("destroy", "tank");
    system($cmd, @args) == 0 or die "Error on destroy of the pool: $?";
    $logger->info("Finished destruction of tank...");
}
