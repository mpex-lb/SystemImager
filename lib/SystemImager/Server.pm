#
# "SystemImager" 
#
#  Copyright (C) 1999-2002 Brian Elliott Finley <brian.finley@baldguysoftware.com>
#  Copyright (C) 2002 Bald Guy Software <brian.finley@baldguysoftware.com>
#
#   $Id$
#

package SystemImager::Server;

use strict;
use vars qw($VERSION @mount_points %device_by_mount_point %filesystem_type_by_mount_point);
use Carp;
use XML::Simple;
use File::Path;

$VERSION="SYSTEMIMAGER_VERSION_STRING";

sub create_image_stub {
    my ($class, $stub_dir, $imagename, $image_dir) = @_;

    open(OUT,">$stub_dir/40$imagename") or return undef;
    print OUT "[$imagename]\n\tpath=$image_dir\n\n";
    close OUT;
}

sub remove_image_stub {
    my ($class, $stub_dir, $imagename) = @_;
    unlink "$stub_dir/40$imagename" or return undef;
}

sub gen_rsyncd_conf {
    my ($class, $stub_dir, $rsyncconf) = @_;

    opendir STUBDIR, $stub_dir or return undef;
      my @stubfiles = readdir STUBDIR;
    closedir STUBDIR;

    #
    # For a stub file to be used, that stub file's name must:
    # o start with one or more digits
    # o have one or more letters and or underscores
    # o have no other characters
    #
    # -BEF-
    #
    @stubfiles = grep (/^\d+/, @stubfiles);      # Must start with a digit
    @stubfiles = grep (!/~$/, @stubfiles);       # Can't end with a tilde (~)
    @stubfiles = grep (!/\.bak$/, @stubfiles);   # Can't end with .bak
    @stubfiles = sort @stubfiles;

    open(RSYNC_CONF, ">$rsyncconf") or return undef;
      foreach my $stub_file (@stubfiles) {
        my $file = "$stub_dir/$stub_file";

        if ( -f $file ) {
          open(STUBFILE, "<$file") or return undef;
          while (<STUBFILE>) {
            print RSYNC_CONF;
          }
          close STUBFILE;
        }
      }
    close RSYNC_CONF;
}

sub add2rsyncd {
    my ($class, $rsyncconf, $imagename, $image_dir) = @_;
    
    if(!_imageexists($rsyncconf, $imagename)) {
        open(OUT,">>$rsyncconf") or return undef;
        print OUT "[$imagename]\n\tpath=$image_dir\n\n";
        close OUT;
        return 1;
    }
    return 1;
}

sub _imageexists {
    my ($rsyncconf, $imagename) = @_;
    open(IN,"<$rsyncconf") or return undef;
    if(grep(/\[$imagename\]/, <IN>)) {
        close(IN);
        return 1;
    }
    return undef;
}

sub validate_post_install_option {
  my $post_install=$_[1];

  unless(($post_install eq "beep") or ($post_install eq "reboot") or ($post_install eq "shutdown")) { 
    die qq(\nERROR: -post-install must be beep, reboot, or shutdown.\n\n       Try "-help" for more options.\n);
  }
  return 0;
}

sub validate_ip_assignment_option {
  my $ip_assignment_method=$_[1];

  $ip_assignment_method = lc $ip_assignment_method;
  unless(
    ($ip_assignment_method eq "")
    or ($ip_assignment_method eq "static_dhcp")
    or ($ip_assignment_method eq "dynamic_dhcp")
    or ($ip_assignment_method eq "static")
    or ($ip_assignment_method eq "replicant")
  ) { die qq(\nERROR: -ip-assignment must be static, static_dhcp, dynamic_dhcp, or replicant.\n\n       Try "-help" for more options.\n); }
  return 0;
}

sub get_image_path {
    my ($class,  $stub_dir, $imagename) = @_;

    open (FILE, "<$stub_dir/40$imagename") or return undef;
    while (<FILE>) {
	if (/^\s*path\s*=\s*(\S+)\s$/) {
	    close FILE;
	    return $1;
	}
    }
    close FILE;
    return undef;
}

# Usage:
# my $path = SystemImager::Server->get_image_path( $rsync_stub_dir, $image );
sub get_full_path_to_image_from_rsyncd_conf {

    print "FATAL: get_full_path_to_image_from_rsyncd_conf is depricated.\n";
    print "Please tell this tool to call the following subroutine instead:\n";
    print 'SystemImager::Server->get_image_path( $rsync_stub_dir, $image );' . "\n";
    die;
}


# Usage:  
# _read_partition_info_and_prepare_parted_commands( $image_dir, $auto_install_script_conf );
sub _read_partition_info_and_prepare_parted_commands {

    my ($image_dir, $file) = @_;

    my $config = XMLin($file, keyattr => { disk => "+dev", part => "+num" }, forcearray => 1 );  

    #
    # Ok.  Now that we've read all of the partition scheme info into hashes, let's do stuff with it. -BEF-
    #
    foreach my $dev (sort (keys ( %{$config->{disk}} ))) {

        my $label_type = $config->{disk}->{$dev}->{label_type};
        my (
            $highest_partition_number, 
            $highest_partition_number_that_could_be_skipped, 
            $m, 
            $cmd, 
            $empty_partition_count, 
            $remaining_empty_partitions, 
            $MB_from_end_of_disk
        );

        print MASTER_SCRIPT "### BEGIN partition $dev ###\n";
        print MASTER_SCRIPT qq(echo "Partitioning $dev..."\n);
        print MASTER_SCRIPT qq(echo "Old partition table for $dev:"\n);
        print MASTER_SCRIPT "parted -s -- $dev print\n\n";

        print MASTER_SCRIPT "# Create disk label.  This ensures that all remnants of the old label, whatever\n";
        print MASTER_SCRIPT "# type it was, are removed and that we're starting with a clean label.\n";
        $cmd = "parted -s -- $dev mklabel $label_type || shellout";
        print MASTER_SCRIPT qq(echo "$cmd"\n);
        print MASTER_SCRIPT "$cmd\n\n";

        print MASTER_SCRIPT "# Get the size of the destination disk so that we can make the partitions fit properly.\n";
        print MASTER_SCRIPT qq(DISK_SIZE=`parted -s $dev print ) . q(| grep 'Disk geometry for' | sed 's/^.*-//g' | sed 's/\..*$//' `) . qq(\n);
        print MASTER_SCRIPT q([ -z $DISK_SIZE ] && shellout) . qq(\n);
        print MASTER_SCRIPT qq(END_OF_LAST_PRIMARY=0\n);

        ### BEGIN Populate the simple hashes. -BEF- ###
        my (
            %end_of_disk,
            %flags,
            %fstype, 
            %p_type, 
            %p_name, 
            %size, 
            %startMB,
            %endMB
        );

        my $unit_of_measurement = lc $config->{disk}->{$dev}->{unit_of_measurement};

        # Make sure the user specified 100% or less of the disk (if used). -BEF-
        if (("$unit_of_measurement" eq "%")
            or ("$unit_of_measurement" eq "percent") 
            or ("$unit_of_measurement" eq "percentage") 
            or ("$unit_of_measurement" eq "percentages")) {

            my $sum;
            foreach my $m (sort (keys ( %{$config->{disk}->{$dev}->{part}} ))) {
                $_ = $config->{disk}->{$dev}->{part}{$m}->{size};
                if ( $_ eq "*" ) { next; }
                if (/[[:alpha:]]/) {
                    print qq(FATAL:  autoinstallscript.conf cannot contain "$_" as a percentage.\n);
                    print qq(        Disk: $dev, partition: $m\n);
                    exit 1;
                }

                $sum += $_;

            }
            if ($sum > 100) {
                print qq(FATAL:  Your autoinstallscript.conf file specifies that "${sum}%" of your disk\n);
                print   "        should be partitioned.  Ummm, I don't think you have that much disk. ;-)\n";
                exit 1;
            }
        } 

        my $end_of_last_primary = 0;
        my $end_of_last_logical;

        foreach my $m (sort (keys ( %{$config->{disk}->{$dev}->{part}} ))) {
            $flags{$m}       = $config->{disk}->{$dev}->{part}{$m}->{flags};
            $fstype{$m}      = $config->{disk}->{$dev}->{part}{$m}->{fs};
            $p_name{$m}      = $config->{disk}->{$dev}->{part}{$m}->{p_name};
            $p_type{$m}      = $config->{disk}->{$dev}->{part}{$m}->{p_type};
            $size{$m}        = $config->{disk}->{$dev}->{part}{$m}->{size};

            # Calculate $startMB and $endMB. -BEF-
            if ("$p_type{$m}" eq "primary") {
                $startMB{$m} = q($END_OF_LAST_PRIMARY);
            
            } elsif ("$p_type{$m}" eq "extended") {
                $startMB{$m} = q($END_OF_LAST_PRIMARY);
            
            } elsif ("$p_type{$m}" eq "logical") {
                $startMB{$m} = q($END_OF_LAST_LOGICAL);
            }

            if (("$unit_of_measurement" eq "mb") 
                or ("$unit_of_measurement" eq "megabytes")) {

                $endMB{$m} = q#$(echo "scale=3; ($START_MB + # . qq#$size{$m})" | bc -l)#;

            } elsif (("$unit_of_measurement" eq "%")
                or ("$unit_of_measurement" eq "percent") 
                or ("$unit_of_measurement" eq "percentage") 
                or ("$unit_of_measurement" eq "percentages")) {

                $endMB{$m} = q#$(echo "scale=3; (# . qq#$startMB{$m}# . q# + ($DISK_SIZE * # . qq#$size{$m} / 100))" | bc -l)#;
            }

        }
        ### END Populate the simple hashes. -BEF- ###

        # Figure out what the highest partition number is. -BEF-
        foreach (sort { $a <=> $b } (keys ( %{$config->{disk}->{$dev}->{part}} ))) {
            $highest_partition_number = $_;
        }

        ### BEGIN For empty partitions, change $endMB appropriately. -BEF- ###
        #
        $m = $highest_partition_number;
        $empty_partition_count = 0;
        $MB_from_end_of_disk = 0;
        my %minors_to_remove;

        until ($m == 0) {
          unless ($endMB{$m}) {
            $empty_partition_count++;

            $endMB{$m} = '$(( $DISK_SIZE - ' . "$MB_from_end_of_disk" . ' ))';
            $MB_from_end_of_disk++;

            $startMB{$m} = '$(( $DISK_SIZE - ' . "$MB_from_end_of_disk" . ' ))';
            $MB_from_end_of_disk++;

            $p_type{$m} = "primary";
            $fstype{$m} = "ext2";
            $p_name{$m} = "-";
            $flags{$m}  = "-";

            $minors_to_remove{$m} = "remove";  # This could be any value.  I just chose remove. -BEF-
          }

          $m--;
        }

        # For partitions that go to the end of the disk, tell $endMB to grow to end of disk. -BEF-
        foreach $m (keys %endMB) {
            if ( $size{$m} eq "*" ) {
                $endMB{$m} = '$(( $DISK_SIZE - ' . "$MB_from_end_of_disk" . ' ))';
            }
        }
        ### END For empty partitions, change $endMB appropriately. -BEF- ###


        # Start out with a minor of 1.  We iterate through all minors from one 
        # to $highest_partition_number, and fool parted by creating bogus partitions
        # where there are gaps in the partition numbers, then later removing them. -BEF-
        #
        $m = "1";
        until ($m > $highest_partition_number) {

          if ($fstype{$m} eq "-") { $fstype{$m} = ""; }

          ### Print partitioning commands. -BEF-
          print MASTER_SCRIPT "\n";

          $cmd = "Creating partition ${dev}${m}.";
          print MASTER_SCRIPT qq(echo "$cmd"\n);

          print MASTER_SCRIPT qq(START_MB=$startMB{$m}\n);
          print MASTER_SCRIPT qq(END_MB=$endMB{$m}\n);
          $cmd = qq(parted -s -- $dev mkpart $p_type{$m} $fstype{$m} ) . q($START_MB $END_MB) . qq( || shellout);
          print MASTER_SCRIPT qq(echo "$cmd"\n);
          print MASTER_SCRIPT "$cmd\n";

          # Leave info behind for the next partition. -BEF-
          if ("$p_type{$m}" eq "primary") {
            print MASTER_SCRIPT q(END_OF_LAST_PRIMARY=$END_MB) . qq(\n);

          } elsif ("$p_type{$m}" eq "extended") {
            print MASTER_SCRIPT q(END_OF_LAST_PRIMARY=$END_MB) . qq(\n);
            print MASTER_SCRIPT q(END_OF_LAST_LOGICAL=$START_MB) . qq(\n);

          } elsif ("$p_type{$m}" eq "logical") {
            print MASTER_SCRIPT q(END_OF_LAST_LOGICAL=$END_MB) . qq(\n);

          }

          # Name any partitions that need that kinda treatment.
          #
          # XXX Currently, we are assuming that no one is using a rediculously long name.  
          # parted's output doesn't make it easy for us, and it is currently possible for
          # a long name to get truncated, and the rest would be considered flags.   
          # Consider submitting a patch to parted that would print easily parsable output 
          # with n/a values "-" and no spaces in the flags. -BEF-
          #
          if (($label_type eq "gpt") and ($p_name{$m} ne "-")) {  # We're kinda assuming no one names their partitions "-". -BEF-
            $cmd = "parted -s -- $dev name $m $p_name{$m} || shellout\n";
            print MASTER_SCRIPT "echo $cmd";
            print MASTER_SCRIPT "$cmd";
          }

          ### Deal with flags for each partition. -BEF-
          if ($flags{$m} ne "-") {

            # $flags{$m} will look something like "boot,lba,raid" or "boot" at this point.
            my @flags = split (/,/, $flags{$m});

            foreach my $flag (@flags) {
              # Parted 1.6.0 doesn't seem to want to tag gpt partitions with lba.  Hmmm. -BEF-
              if (($flag eq "lba") and ($label_type eq "gpt")) { next; }
              $cmd = "parted -s -- $dev set $m $flag on || shellout\n";
              print MASTER_SCRIPT "echo $cmd";
              print MASTER_SCRIPT "$cmd";
            }
          }

          $m++;
        }

        # Kick the minors out.  (remove temporary partitions) -BEF-
        foreach $m (keys %minors_to_remove) {
          print MASTER_SCRIPT "\n# Gotta lose this one (${dev}${m}) to make the disk look right.\n";
          $cmd = "parted -s -- $dev rm $m  || shellout";
          print MASTER_SCRIPT qq(echo "$cmd"\n);
          print MASTER_SCRIPT "$cmd\n";
        }

        print MASTER_SCRIPT "\n";
        print MASTER_SCRIPT qq(echo "New partition table for $dev:"\n);
        $cmd = "parted -s -- $dev print";
        print MASTER_SCRIPT qq(echo "$cmd"\n);
        print MASTER_SCRIPT "$cmd\n";
        print MASTER_SCRIPT "### END partition $dev ###\n";
        print MASTER_SCRIPT "\n";
        print MASTER_SCRIPT "\n";
    }
}


sub _in_script_add_standard_header_stuff {
  my ($image, $script_name) = @_;
  print MASTER_SCRIPT << 'EOF';
#!/bin/sh

#
# "SystemImager"
#
#  Copyright (C) 1999-2001 Brian Elliott Finley <brian.finley@baldguysoftware.com>
#  Copyright (C) 2002 Bald Guy Software <brian.finley@baldguysoftware.com>
#
EOF

  print MASTER_SCRIPT "# This master autoinstall script was created with SystemImager v$VERSION\n";
  print MASTER_SCRIPT "\n";
  print MASTER_SCRIPT "VERSION=$VERSION\n";

  print MASTER_SCRIPT << 'EOF';

PATH=/sbin:/bin:/usr/bin:/usr/sbin:/tmp
ARCH=`uname -m \
| sed -e s/i.86/i386/ -e s/sun4u/sparc64/ -e s/arm.*/arm/ -e s/sa110/arm/`

# Pull in variables left behind by the linuxrc script.
# This information is passed from the linuxrc script on the autoinstall media 
# via /tmp/variables.txt.  Apparently the shell we use in BOEL is not 
# intelligent enough to take a "set -a" parameter.
#
. /tmp/variables.txt || shellout

shellout() {
  exec cat /etc/issue ; exit 1
}

EOF

  print MASTER_SCRIPT  q([ -z $IMAGENAME ] && ) . qq(IMAGENAME=$image\n);
  print MASTER_SCRIPT  q([ -z $OVERRIDES ] && ) . qq(OVERRIDES="$script_name"\n);
  print MASTER_SCRIPT << 'EOF';

### BEGIN Check to be sure this not run from a working machine ###
# Test for mounted SCSI or IDE disks
mount | grep [hs]d[a-z][1-9] > /dev/null 2>&1
[ $? -eq 0 ] &&  echo Sorry.  Must not run on a working machine... && shellout

# Test for mounted software RAID devices
mount | grep md[0-9] > /dev/null 2>&1
[ $? -eq 0 ] &&  echo Sorry.  Must not run on a working machine... && shellout

# Test for mounted hardware RAID disks
mount | grep c[0-9]+d[0-9]+p > /dev/null 2>&1
[ $? -eq 0 ] &&  echo Sorry.  Must not run on a working machine... && shellout
### END Check to be sure this not run from a working machine ###


### BEGIN Stop RAID devices before partitioning begins ###
# Q1) Why did they get started in the first place?  
# A1) So we can pull a local.cfg file off a root mounted software RAID system.
#     They may not be started on your system -- they would only be started if
#     you did the stuff in Q3 below.
#
# Q2) Why didn't my local.cfg on my root mounted software RAID work for me 
#     with the standard kernel flavour?
# A2) The standard kernel flavour uses modules for the software RAID drivers --
#     therefore, software RAID is not available at the point in the boot process
#     where BOEL needs to read the local.cfg file.  They are only pulled over 
#     when this script is run, which is, of course, only runnable if it was
#     pulled over the network using the settings that you would have wanted it
#     to get from the local.cfg file, which it couldn't.  Right?
#
# Q3) Whatever.  So how do I make it work with a local.cfg file on my root
#     mounted software RAID?  
# A3) Compile an autoinstall kernel with software RAID, and any other drivers 
#     you might need built in (filesystem, SCSI drivers, etc.).
#
#     XXX To make this work now, we'll also need to pass the filesystem type in 
#         the LAST_ROOT append parameter.  Perhaps like 
#         "LAST_ROOT=/dev/md0,ext3".
#      
# Find running raid devices
if [ -f /proc/mdstat ]; then
  RAID_DEVICES=` cat /proc/mdstat | grep ^md | sed 's/ .*$//g' `

  # raidstop will not run unless a raidtab file exists
  echo "" >> /etc/raidtab || shellout

  # turn dem pesky raid devices off!
  for RAID_DEVICE in ${RAID_DEVICES}
  do
    DEV="/dev/${RAID_DEVICE}"
    # we don't do a shellout here because, well I forgot why, but we don't.
    echo "raidstop ${DEV}" && raidstop ${DEV}
  done
fi
### END Stop RAID devices before partitioning begins ###


EOF
}


sub _add_proc_to_list_of_filesystems_to_mount_on_autoinstall_client {
  #  The following allows a proc filesystem to be mounted in the fakeroot.
  #  This provides /proc to programs which are called by SystemImager
  #  (eg. System Configurator).

  push (@mount_points, '/proc');
  $device_by_mount_point{'/proc'} = 'proc';
  $filesystem_type_by_mount_point{'proc'} = 'proc';
}


# Usage:  
# _upgrade_partition_schemes_to_generic_style($image_dir, $config_dir);
sub _upgrade_partition_schemes_to_generic_style {

  my ($image_dir, $config_dir) = @_;

  my $new_file = "$config_dir/autoinstallscript.conf";
  my $partition_dir = "$config_dir/partitionschemes";

  # Disk types ide and scsi are pretty self explanatory.  Here are 
  # some others: -BEF-
  # o rd is a dac960 device (mylex extremeraid is an example)
  # o ida is a compaq smartscsi device
  # o cciss is a compaq smartscsi device
  #
  my @disk_types = qw( . rd ida cciss );  # The . is for ide and scsi disks. -BEF-

  foreach my $type (@disk_types) {
    my $dir;
    if ($type eq ".") {
      $dir = $image_dir . $partition_dir;
    } else {
      $dir = $image_dir . $partition_dir . "/" . $type;
    }

    if(-d $dir) {
      opendir(DIR, $dir) || die "Can't read the $dir directory.";
        while(my $device = readdir(DIR)) {

          # Skip over any "dot" files. -BEF-
          #
          if ($device =~ /^\./) { next; }

          my $file = "$dir/$device";

          if (-f $file) {
            SystemImager::Common->save_partition_information($file, "old_sfdisk_file", $new_file);
          }
        }
      close(DIR);
    }
  }
}


sub _get_array_of_disks {

  my ($image_dir, $config_dir) = @_;
  my @disks;

  # Disk types ide and scsi are pretty self explanatory.  Here are 
  # some others: -BEF-
  # o rd is a dac960 device (mylex extremeraid is an example)
  # o ida is a compaq smartscsi device
  # o cciss is a compaq smartscsi device
  #
  my @disk_types = qw(ide scsi rd ida cciss);

  my $partition_dir = "$config_dir/partitionschemes";
  foreach my $type (@disk_types) {
    my $dir = $image_dir . $partition_dir . "/" . $type;
    if(-d $dir) {
      opendir(DIR, $dir) || die "Can't read the $dir directory.";
        while(my $device = readdir(DIR)) {

          # Skip over any "dot" files. -BEF-
          if ($device =~ /^\./) { next; }

          # Only process regular files.
          if (-f "$dir/$device") {

            # Keep the device name and directory.
            push @disks, "$type/$device";
          }
        
        }
      close(DIR);
    }
  }
  return @disks;
}


# Description:
# Read configuration information from /etc/systemimager/autoinstallscript.conf
# and write filesystem creation commands to the autoinstall script. -BEF-
#
# Usage:
# _write_out_mkfs_commands( $image_dir, $auto_install_script_conf );
#
sub _write_out_mkfs_commands {

    my ($image_dir, $file) = @_;

    my $config = XMLin($file, keyattr => { fsinfo => "+line" }, forcearray => 1 );

    # Figure out if software RAID is in use. -BEF-
    #
    my $software_raid;
    foreach my $line (sort numerically (keys ( %{$config->{fsinfo}} ))) {

        # If this line is a comment, skip over. -BEF-
        if ( $config->{fsinfo}->{$line}->{comment} ) { next; }

        # If real_dev isn't set, move on. -BEF-
        unless ($config->{fsinfo}->{$line}->{real_dev}) { next; }

        my $real_dev = $config->{fsinfo}->{$line}->{real_dev};
        if ($real_dev =~ /\/dev\/md/) {
            $software_raid = "true";
        }
    }

    print MASTER_SCRIPT "### BEGIN swap and filesystem creation commands ###\n";
    print MASTER_SCRIPT qq(echo "Load additional filesystem drivers."\n);
    print MASTER_SCRIPT "modprobe reiserfs\n";
    print MASTER_SCRIPT "modprobe ext3\n";
    print MASTER_SCRIPT "modprobe jfs\n";
    print MASTER_SCRIPT "\n";


    if ($software_raid) {

        print MASTER_SCRIPT qq(# Must remove the /etc/raidtab created for the raidstop commands above.\n);
        print MASTER_SCRIPT qq(rm -f /etc/raidtab\n);
        print MASTER_SCRIPT qq(echo\n);
        print MASTER_SCRIPT qq(echo "Pull /etc/raidtab in image over to autoinstall client."\n);
        print MASTER_SCRIPT qq(rsync -av --numeric-ids \$IMAGESERVER::\$IMAGENAME/etc/raidtab /etc/raidtab || echo "No /etc/raidtab in the image directory, hopefully there's one in an override directory."\n);
      
        print MASTER_SCRIPT qq(echo "Pull /etc/raidtab from each override to autoinstall client."\n);
        print MASTER_SCRIPT  q(for OVERRIDE in $OVERRIDES) . qq(\n);
        print MASTER_SCRIPT qq(do\n);
        print MASTER_SCRIPT  q(    rsync -av --numeric-ids $IMAGESERVER::overrides/$OVERRIDE/etc/raidtab /etc/raidtab || echo "No /etc/raidtab in override $OVERRIDE, but that should be OK.") . qq(\n);
        print MASTER_SCRIPT qq(    echo\n);
        print MASTER_SCRIPT qq(done\n);

        print MASTER_SCRIPT qq(if [ -e /etc/raidtab ]; then\n);
		print MASTER_SCRIPT qq(    echo "Ah, good.  Found an /etc/raidtab file.  Proceeding..."\n);
		print MASTER_SCRIPT qq(else\n);
		print MASTER_SCRIPT qq(    echo "No /etc/raidtab file.  Please verify that you have one in your image, or in an override directory."\n);
		print MASTER_SCRIPT qq(    shellout\n);
		print MASTER_SCRIPT qq(fi\n);

        print MASTER_SCRIPT "\n";
        print MASTER_SCRIPT "# Load RAID modules, if necessary, and create software RAID devices.\n";
        print MASTER_SCRIPT "if [ ! -f /proc/mdstat ]; then\n";
        print MASTER_SCRIPT "  modprobe linear\n";
        print MASTER_SCRIPT "  modprobe raid0\n";
        print MASTER_SCRIPT "  modprobe raid1\n";
        print MASTER_SCRIPT "  modprobe raid5\n";
        print MASTER_SCRIPT "fi\n";
        print MASTER_SCRIPT "\n";

    }


    foreach my $line (sort numerically (keys ( %{$config->{fsinfo}} ))) {
        
        my $cmd = "";
        # If this line is a comment, skip over. -BEF-
        if ( $config->{fsinfo}->{$line}->{comment} ) { next; }

        # If real_dev isn't set, move on. -BEF-
        unless ($config->{fsinfo}->{$line}->{real_dev}) { next; }

        # If format="no" is set, then skip over this one. -BEF-
        my $format = $config->{fsinfo}->{$line}->{format};
        if (($format) and ( "$format" eq "no")) { next; }

        # mount_dev should contain fs LABEL or UUID information. -BEF-
        my $mount_dev = $config->{fsinfo}->{$line}->{mount_dev};

        my $real_dev = $config->{fsinfo}->{$line}->{real_dev};
        my $mp = $config->{fsinfo}->{$line}->{mp};
        my $fs = $config->{fsinfo}->{$line}->{fs};
        my $options = $config->{fsinfo}->{$line}->{options};
        my $mkfs_opts = $config->{fsinfo}->{$line}->{mkfs_opts};
        unless ($mkfs_opts) { $mkfs_opts = ""; }

        # Deal with filesystems to be mounted read only (ro) after install.  We 
        # still need to write to them to install them. ;)
        $options =~ s/^ro$/rw/;
        $options =~ s/^ro,/rw,/;
        $options =~ s/,ro$/,rw/;
        $options =~ s/,ro,/,rw,/;

        # software RAID devices (/dev/md*)
        if ($real_dev =~ /\/dev\/md/) {
            print MASTER_SCRIPT qq(mkraid --really-force $real_dev || shellout\n);
        }

        # swap
        if ( $config->{fsinfo}->{$line}->{fs} eq "swap" ) {

            # create swap
            $cmd = "mkswap -v1 $real_dev || shellout";
            print MASTER_SCRIPT qq(echo "$cmd"\n);
            print MASTER_SCRIPT "$cmd\n";

            # swapon
            $cmd = "swapon $real_dev || shellout";
            print MASTER_SCRIPT qq(echo "$cmd"\n);
            print MASTER_SCRIPT "$cmd\n";

            print MASTER_SCRIPT "\n";

        # msdos or vfat
        } elsif (( $config->{fsinfo}->{$line}->{fs} eq "vfat" ) or ( $config->{fsinfo}->{$line}->{fs} eq "msdos" )){

            # create fs
            $cmd = "mkdosfs $mkfs_opts -v $real_dev || shellout";
            print MASTER_SCRIPT qq(echo "$cmd"\n);
            print MASTER_SCRIPT "$cmd\n";

            # mkdir
            $cmd = "mkdir -p /a$mp || shellout";
            print MASTER_SCRIPT qq(echo "$cmd"\n);
            print MASTER_SCRIPT "$cmd\n";

            # mount
            $cmd = "mount $real_dev /a$mp -t $fs -o $options || shellout";
            print MASTER_SCRIPT qq(echo "$cmd"\n);
            print MASTER_SCRIPT "$cmd\n";
            
            print MASTER_SCRIPT "\n";


        # ext2
        } elsif ( $config->{fsinfo}->{$line}->{fs} eq "ext2" ) {

            # create fs
            $cmd = "mke2fs $real_dev || shellout";
            print MASTER_SCRIPT qq(echo "$cmd"\n);
            print MASTER_SCRIPT "$cmd\n";

            if ($mount_dev) {
                # add LABEL if necessary
                if ($mount_dev =~ /LABEL=/) {
                    my $label = $mount_dev;
                    $label =~ s/LABEL=//;
                
                    $cmd = "tune2fs -L $label $real_dev";
                    print MASTER_SCRIPT qq(echo "$cmd"\n);
                    print MASTER_SCRIPT "$cmd\n";
                }
                
                # add UUID if necessary
                if ($mount_dev =~ /UUID=/) {
                    my $uuid = $mount_dev;
                    $uuid =~ s/UUID=//;
                
                    $cmd = "tune2fs -U $uuid $real_dev";
                    print MASTER_SCRIPT qq(echo "$cmd"\n);
                    print MASTER_SCRIPT "$cmd\n";
                }
            }

            # mkdir
            $cmd = "mkdir -p /a$mp || shellout";
            print MASTER_SCRIPT qq(echo "$cmd"\n);
            print MASTER_SCRIPT "$cmd\n";

            # mount
            $cmd = "mount $real_dev /a$mp -t $fs -o $options || shellout";
            print MASTER_SCRIPT qq(echo "$cmd"\n);
            print MASTER_SCRIPT "$cmd\n";
            
            print MASTER_SCRIPT "\n";


        # ext3
        } elsif ( $config->{fsinfo}->{$line}->{fs} eq "ext3" ) {

            # create fs
            $cmd = "mke2fs -j $real_dev || shellout";
            print MASTER_SCRIPT qq(echo "$cmd"\n);
            print MASTER_SCRIPT "$cmd\n";

            if ($mount_dev) {
                # add LABEL if necessary
                if ($mount_dev =~ /LABEL=/) {
                    my $label = $mount_dev;
                    $label =~ s/LABEL=//;
                
                    $cmd = "tune2fs -L $label $real_dev";
                    print MASTER_SCRIPT qq(echo "$cmd"\n);
                    print MASTER_SCRIPT "$cmd\n";
                }
                
                # add UUID if necessary
                if ($mount_dev =~ /UUID=/) {
                    my $uuid = $mount_dev;
                    $uuid =~ s/UUID=//;
                
                    $cmd = "tune2fs -U $uuid $real_dev";
                    print MASTER_SCRIPT qq(echo "$cmd"\n);
                    print MASTER_SCRIPT "$cmd\n";
                }
            }

            # mkdir
            $cmd = "mkdir -p /a$mp || shellout";
            print MASTER_SCRIPT qq(echo "$cmd"\n);
            print MASTER_SCRIPT "$cmd\n";

            # mount
            $cmd = "mount $real_dev /a$mp -t $fs -o $options || shellout";
            print MASTER_SCRIPT qq(echo "$cmd"\n);
            print MASTER_SCRIPT "$cmd\n";
            
            print MASTER_SCRIPT "\n";


        # reiserfs
        } elsif ( $config->{fsinfo}->{$line}->{fs} eq "reiserfs" ) {

            # create fs
            $cmd = "echo y | mkreiserfs $real_dev || shellout";
            print MASTER_SCRIPT qq(echo "$cmd"\n);
            print MASTER_SCRIPT "$cmd\n";

            # mkdir
            $cmd = "mkdir -p /a$mp || shellout";
            print MASTER_SCRIPT qq(echo "$cmd"\n);
            print MASTER_SCRIPT "$cmd\n";

            # mount
            $cmd = "mount $real_dev /a$mp -t $fs -o $options || shellout";
            print MASTER_SCRIPT qq(echo "$cmd"\n);
            print MASTER_SCRIPT "$cmd\n";
            
            print MASTER_SCRIPT "\n";

        # jfs
        } elsif ( $config->{fsinfo}->{$line}->{fs} eq "jfs" ) {

            # create fs
            $cmd = "mkfs.jfs -q $real_dev || shellout";
            print MASTER_SCRIPT qq(echo "$cmd"\n);
            print MASTER_SCRIPT "$cmd\n";

            # mkdir
            $cmd = "mkdir -p /a$mp || shellout";
            print MASTER_SCRIPT qq(echo "$cmd"\n);
            print MASTER_SCRIPT "$cmd\n";

            # mount
            $cmd = "mount $real_dev /a$mp -t $fs -o $options || shellout";
            print MASTER_SCRIPT qq(echo "$cmd"\n);
            print MASTER_SCRIPT "$cmd\n";
            
            print MASTER_SCRIPT "\n";

        }

    }
    print MASTER_SCRIPT "### END swap and filesystem creation commands ###\n";
    print MASTER_SCRIPT "\n";
    print MASTER_SCRIPT "\n";
}


# Description:
# Read configuration information from /etc/systemimager/autoinstallscript.conf
# and generate commands to create an fstab file on the autoinstall client
# immediately after pulling down the image. -BEF-
#
# Usage:
# _write_out_new_fstab_file ( $image_dir, $auto_install_script_conf );
#
sub _write_out_new_fstab_file {

    my ($image_dir, $file) = @_;

    my $config = XMLin($file, keyattr => { fsinfo => "+line" }, forcearray => 1 );

    print MASTER_SCRIPT "### BEGIN generate new fstab file from autoinstallscript.conf ###\n";
    print MASTER_SCRIPT qq(rm -f /a/etc/fstab\n);

    foreach my $line (sort numerically (keys ( %{$config->{fsinfo}} ))) {
        my $comment   = $config->{fsinfo}->{$line}->{comment};
        my $mount_dev = $config->{fsinfo}->{$line}->{mount_dev};
        unless ($mount_dev) 
            { $mount_dev = $config->{fsinfo}->{$line}->{real_dev}; }
        my $mp        = $config->{fsinfo}->{$line}->{mp};
        my $options   = $config->{fsinfo}->{$line}->{options};
        my $fs        = $config->{fsinfo}->{$line}->{fs};
        my $dump      = $config->{fsinfo}->{$line}->{dump};
        my $pass      = $config->{fsinfo}->{$line}->{pass};

        if ($comment) {

            # Turn special characters back into themselves. -BEF-
            #
            $_ = $comment;
            s/\\074/</g;
            s/\\076/>/g;

            # If there is a " (double quote), then keep it in octal, and use 
            # echo -e. -BEF-
            #
            if (/\\042/) {  
                print MASTER_SCRIPT qq(echo -e "$_" >> /a/etc/fstab\n);
            } else {
                print MASTER_SCRIPT qq(echo "$_" >> /a/etc/fstab\n);
            }
        } else {
            print MASTER_SCRIPT qq(echo "$mount_dev\t$mp\t$fs\t$options\t$dump\t$pass" >> /a/etc/fstab\n);
        }
    }
    print MASTER_SCRIPT "### END generate new fstab file from autoinstallscript.conf ###\n";
    print MASTER_SCRIPT "\n";
    print MASTER_SCRIPT "\n";
}


# Description:
# Modify a sort so that 10 comes after 2.  
# Standard sort: (sort $numbers);               # 1,10,2,3,4,5,6,7,8,9
# Numerically:   (sort numerically $numbers);   # 1,2,3,4,5,6,7,8,9,10
#
# Usage:
# foreach my $line (sort numerically (keys ( %{hash} )))
#
sub numerically {
    $a <=> $b;
}


# Description:
# Read configuration information from /etc/systemimager/autoinstallscript.conf
# and generate commands to create an fstab file on the autoinstall client
# immediately after pulling down the image. -BEF-
#
# Usage:
# _write_out_umount_commands ( $image_dir, $auto_install_script_conf );
#
sub _write_out_umount_commands {

    my ($image_dir, $file) = @_;

    my $config = XMLin($file, keyattr => { fsinfo => "+line" }, forcearray => 1 );

    print MASTER_SCRIPT "### BEGIN Unmount filesystems ###\n";

    # We can't use mp as a hash key, because not all fsinfo lines will have an 
    # mp entry.  Associate filesystems by mount points in a hash here, then we
    # can reverse sort by mount point below to unmount them all. -BEF-
    #
    my %fs_by_mp;   
    foreach my $line (reverse sort (keys ( %{$config->{fsinfo}} ))) {

        if ( $config->{fsinfo}->{$line}->{fs} ) { 
            my $mp = $config->{fsinfo}->{$line}->{mp};
            my $fs = $config->{fsinfo}->{$line}->{fs};
            $fs_by_mp{$mp} = $fs;
        }
    }

    # Cycle through the mount points in reverse and umount those filesystems.
    # -BEF-
    #
    foreach my $mp (reverse sort (keys ( %fs_by_mp ))) {
       
        my $fs = $fs_by_mp{$mp};
        unless( 
               ($fs eq "ext2") 
               or ($fs eq "ext3") 
               or ($fs eq "reiserfs")
               or ($fs eq "msdos")
               or ($fs eq "vfat")
               or ($fs eq "jfs")
        ) { next; }

        # umount
        my $cmd = "umount /a$mp || shellout";
        print MASTER_SCRIPT qq(echo "$cmd"\n);
        print MASTER_SCRIPT "$cmd\n";
        print MASTER_SCRIPT "\n";

    }

    print MASTER_SCRIPT "### END Unmount filesystems ###\n";
    print MASTER_SCRIPT "\n";
    print MASTER_SCRIPT "\n";
}


sub create_autoinstall_script{

  my (  $module, 
        $script_name, 
        $auto_install_script_dir, 
        $config_dir, 
        $image, 
        $image_dir, 
        $ip_assignment_method, 
        $post_install,
        $auto_install_script_conf,
        $ssh_user
    ) = @_;

  # Lose the /etc/mtab file.  It can cause confusion on the autoinstall client, making 
  # it think that filesystems are mounted when they really aren't.  And because it is
  # automatically updated on running systems, we don't really need it for anything 
  # anyway. -BEF-
  #
  my $file="$image_dir/etc/mtab";
  if (-f $file) {
    unlink "$file" or croak("Can't remove $file!");
  }

  $file = "$auto_install_script_dir/$script_name.master";
  open (MASTER_SCRIPT, ">$file") || die "Can't open $file for writing\n";

  _in_script_add_standard_header_stuff($image, $script_name);

  _upgrade_partition_schemes_to_generic_style($image_dir, $config_dir);

  _add_proc_to_list_of_filesystems_to_mount_on_autoinstall_client();

  _read_partition_info_and_prepare_parted_commands( $image_dir, $auto_install_script_conf );

  _write_out_mkfs_commands( $image_dir, $auto_install_script_conf );
  
  ### BEGIN pull the image down ###
  print MASTER_SCRIPT << 'EOF';
# Filler up!
#
# If we are installing over ssh, we must limit the bandwidth used by 
# rsync with the --bwlimit option.  This is because of a bug in ssh that
# causes a deadlock.  The only problem with --bwlimit is that it slows 
# down your autoinstall significantly.  We try to guess which one you need:
# o if you ran getimage with -ssh-user, we presume you need --bwlimit
# o if you ran getimage without -ssh-user, we presume you don't need 
#   --bwlimit and would rather have a faster autoinstall.
#   XXX verify that this is still true... -BEF-
#
# Both options are here for your convenience.  We have done our best to 
# choose the one you need and have commented out the other.
#
EOF

  if ($ssh_user) {
    # using ssh
    print MASTER_SCRIPT "rsync -av  --exclude=lost+found/ --bwlimit=10000 --numeric-ids \$IMAGESERVER::\$IMAGENAME/ /a/ || shellout\n";
    print MASTER_SCRIPT "#rsync -av  --exclude=lost+found/ --numeric-ids \$IMAGESERVER::\$IMAGENAME/ /a/ || shellout\n\n";
  } else {
    # not using ssh
    print MASTER_SCRIPT "#rsync -av  --exclude=lost+found/ --bwlimit=10000 --numeric-ids \$IMAGESERVER::\$IMAGENAME/ /a/ || shellout\n";
    print MASTER_SCRIPT "rsync -av  --exclude=lost+found/ --numeric-ids \$IMAGESERVER::\$IMAGENAME/ /a/ || shellout\n\n";
  }
  ### END pull the image down ###


  ### BEGIN graffiti ###
  print MASTER_SCRIPT "# Leave notice of which image is installed on the client\n";
  print MASTER_SCRIPT "echo \$IMAGENAME > /a/etc/systemimager/IMAGE_LAST_SYNCED_TO || shellout\n";
  ### END graffiti ###
  
  _write_out_new_fstab_file( $image_dir, $auto_install_script_conf );

  ### BEGIN overrides stuff ###
  # Create default overrides directory. -BEF-
  #
  my $dir = "/var/lib/systemimager/overrides/$script_name";
  if (! -d "$dir")  {
    mkdir("$dir", 0750) or die "FATAL: Can't make directory $dir\n";
  }

  # Add code to autoinstall script. -BEF-
  print MASTER_SCRIPT   qq(### BEGIN overrides ###\n);
  print MASTER_SCRIPT   q(for OVERRIDE in $OVERRIDES) . qq(\n);
  print MASTER_SCRIPT   q(do) . qq(\n);
  print MASTER_SCRIPT   q(    rsync -av --numeric-ids $IMAGESERVER::overrides/$OVERRIDE/ /a/ || echo "Override directory $OVERRIDE doesn't seem to exist, but that may be OK.") . qq(\n);
  print MASTER_SCRIPT   q(done) . qq(\n);
  print MASTER_SCRIPT   qq(### END overrides ###\n);
  ### END overrides stuff ###
  
  print MASTER_SCRIPT   qq(\n);
  print MASTER_SCRIPT   qq(\n);

  ### BEGIN System Configurator setup ###
  print MASTER_SCRIPT "### BEGIN systemconfigurator ###\n";

  # System Configurator for static IP
  if ($ip_assignment_method eq "static") { 
    print MASTER_SCRIPT <<'EOF';
# Configure the client's hardware, network interface, and boot loader.
chroot /a/ systemconfigurator --configsi --stdin <<EOL || shellout

[NETWORK]
HOSTNAME = $HOSTNAME
DOMAINNAME = $DOMAINNAME
GATEWAY = $GATEWAY

[INTERFACE0]
DEVICE = eth0
TYPE = static
IPADDR = $IPADDR
NETMASK = $NETMASK
EOL


EOF

  # System Configurator for static dhcp
  } elsif ($ip_assignment_method eq "static_dhcp") {
    print MASTER_SCRIPT <<'EOF';
# Configure the client's hardware, network interface, and boot loader.
chroot /a/ systemconfigurator --configsi --stdin <<EOL || shellout

[INTERFACE0]
DEVICE = eth0
TYPE = dhcp
EOL


EOF


  } elsif ($ip_assignment_method eq "replicant") {
    print MASTER_SCRIPT << 'EOF';
# Configure the client's boot loader.
chroot /a/ systemconfigurator --runboot || shellout


EOF

  } else { # aka elsif ($ip_assignment_method eq "dynamic_dhcp")
    print MASTER_SCRIPT <<'EOF';
# Configure the client's hardware, network interface, and boot loader.
chroot /a/ systemconfigurator --configsi --stdin <<EOL || shellout

[NETWORK]
HOSTNAME = $HOSTNAME
DOMAINNAME = $DOMAINNAME

[INTERFACE0]
DEVICE = eth0
TYPE = dhcp
EOL


EOF

  }  ### END System Configurator setup ###
  print MASTER_SCRIPT "### END systemconfigurator ###\n";


  print MASTER_SCRIPT "\n";
  print MASTER_SCRIPT "\n";

  _write_out_umount_commands( $image_dir, $auto_install_script_conf );

  print MASTER_SCRIPT "\n";

  print MASTER_SCRIPT "# Take network interface down\n";
  print MASTER_SCRIPT "ifconfig eth0 down || shellout\n";
  print MASTER_SCRIPT "\n";

  if ($post_install eq "beep") {
    print MASTER_SCRIPT << 'EOF';
# Cause the system to make noise and display an "I'm done." message
ralph="sick"
count="1"
while [ $ralph="sick" ]
do
  echo -n -e "\\a"
  [ $count -lt 60 ] && echo "I've been done for $count seconds.  Reboot me already!"
  [ $(($count / 60 * 60)) = $count ] && echo "I've been done for $(($count / 60)) minutes now.  Reboot me already!"
  sleep 1
  count=$(($count + 1))
done


EOF


  } elsif ($post_install eq "reboot") {
    #reboot stuff
    print MASTER_SCRIPT "# reboot the autoinstall client\n";
    print MASTER_SCRIPT "shutdown -r now\n";
    print MASTER_SCRIPT "\n";
  } elsif ($post_install eq "shutdown") {
    #shutdown stuff
    print MASTER_SCRIPT "# shutdown the autoinstall client\n";
    print MASTER_SCRIPT "shutdown -h now\n";
    print MASTER_SCRIPT "\n";
  }
  ### END end of autoinstall options ###

  close(MASTER_SCRIPT);
} # sub create_autoinstall_script 
