use strict;

sub merge
{
	my $destFile		= @_[0];
	my @sourceFiles		= @_[1 .. $#_];

	print "Merging ( @sourceFiles ) into $destFile:\n";

	unlink( $destFile );
	open( destFD, '>', $destFile ) or 
		die( "Couldn't open $destFile\n" );

	binmode( destFD );

	my $buff;

	foreach my $srcFile ( @sourceFiles )
	{
		open( srcFD, '<', $srcFile ) or
			die( "Couldn't open $srcFile\n" );

		binmode( srcFD );

		print( "\tWriting $srcFile..." );

		while ( 
			read( srcFD, $buff, 65536 ) 
				and print( destFD $buff )
		) {};
		
		print( "OK\n" );

		close( srcFD ) or
			die( "Couldn't close $srcFile\n" );
	}
	
	close( destFD ) or
		die( "Couldn't close $destFile\n" );
}

sub header
{
	my $File		= @_[0];

	my $tempFile = $File . ".tmp";

	print "Adding magic header to $File:\n";

	unlink( $tempFile );
	open( tempFD, '>', $tempFile ) or 
		die( "Couldn't open $tempFile\n" );

	my $magic=sprintf("%c%c%c%c",0x03,0xCB,0xA7,0xF2);
	print( tempFD $magic);

	binmode( tempFD );

	my $buff;

	open( FD, '<', $File ) or
		die( "Couldn't open $File\n" );

	binmode( FD );

	print( "\tReading $File..." );
	print( "\tWriting $tempFile..." );

	while ( 
		read( FD, $buff, 65536 ) 
			and print( tempFD $buff )
		) {};
		
	print( "OK\n" );

	close( FD ) or
		die( "Couldn't close $File\n" );
	
	close( tempFD ) or
		die( "Couldn't close $tempFile\n" );
		
	print( "Moving $tempFile to $File -> " );
	unlink( $File );
	rename( $tempFile, $File );
	print( "OK\n" );
		
}


sub printUsage
{
	print( "Usage:\n" );
	print( "\tmerge destfile [startfile [endfile]]      : Merge a collection of files. Specifing no\n" ); 
	print( "\t                                            end file will merge up until the last file.\n" );
	print( "\t                                            Specifying neither will merge all files\n" );
	printf( "\n" );
	printf( "\tclump size                                : Clump every <size> files together\n" ); 
	printf( "\n" );
	print( "\theader file                               : Add magic header to a file\n" ); 
	printf( "\n" );
	printf( "\n\nExamples:	\n" );
	printf( "Let's say we had files 0x0000000E.mal.bin to  0x0000002D.mal.bin to work with.\n" );
	printf( "- Running 'perl merger.pl merge all_files': \n\tWill merge all files into a file 'all_files.mal.bin'\n" );
	printf( "- Running 'perl merger.pl merge last_part 0x00000010.mal.bin': \n\tWill merge all files starting from and including 0x00000010.mal.bin up to and including the last file into a file 'last_part.mal.bin'\n" );
	printf( "- Running 'perl merger.pl merge middle_part 0x00000012.mal.bin 0x00000021.mal.bin': \n\twill merge all files starting from and including 0x00000012.mal.bin to 0x00000021.mal.bin into a file 'middle_part.mal.bin'\n" );
	printf( "- Running 'perl merger.pl clump 5': \n\twill clump every 5 files together. If each file is about 1MB in size, and we have 32 files, then we will get ceiling( 32 / 5 ) = 7 files, each about 5MB in size.\n" );


}

sub trim
{
	my $s = @_[0];

	$s =~ s/^[\s\n]+//;
	$s =~ s/[\s\n]+$//;

	return $s;
}

sub findInArray
{
	my ($v, @l) = @_;

	if ( length( $v ) == 0 )
	{
		return -1;
	}

	for ( my $i = 0; $i <= $#l; $i++ )
	{
		#print( "Compare $v to $l[$i]\n" );
		if ( $l[$i] eq $v )
		{
			return $i;
		}
	}

	printUsage;
	die( "Unrecognized file name '$v'\n" );
}

my $mode = @ARGV[0];
shift( @ARGV );

my $infoFile = "info.txt";

open( fd, '<', $infoFile ) or
	die( "Couldn't open $infoFile\n" );


my @fileIds;
my $line;
my @tmp;

$line = <fd>;
@tmp = split( / /, $line );
my $extension = trim( @tmp[1] );

while( $line = <fd> )
{
	@tmp = split( / /, $line );
	push( @fileIds, trim( @tmp[1] ) );
	$line .= <fd>;
	$line .= <fd>;
	print( "$line\n" );
}

close( fd ) or
	die( "Couldn't close $infoFile\n" ); 


if ( $mode eq "merge" )
{
	my $destFile = @ARGV[0];

	if ( $destFile eq "" )
	{
		die( "You must provide a destination file" )
	}
	else
	{
		$destFile .= "." . $extension;
	}

	my $startFile = @ARGV[1];
	my $endFile = @ARGV[2];

	$startFile = findInArray( $startFile, @fileIds );
	$endFile = findInArray( $endFile, @fileIds );

	#printf( "%d, %d\n", $startFile, $endFile );

	if ( $startFile == -1 )
	{
		$startFile = 0;
	}

	if ( $endFile == -1 )
	{
		$endFile = $#fileIds;	
	}

	my @mergeArgs;

	push( @mergeArgs, $destFile ); 

	printf( "Merging from file %s to %s\n", $fileIds[$startFile], $fileIds[$endFile] );

	for ( my $i = $startFile; $i <= $endFile; $i++ )
	{
		push( @mergeArgs, $fileIds[$i] );
	}

	merge( @mergeArgs );
}
elsif ( $mode eq "clump" )
{
	my $size = @ARGV[0];

	if ( $size <= 1 )
	{
		die( "You must provide a size greater than 1\n" );
	}

	my $i = 0;
	my $j = 0;
	while ( $i <= $#fileIds )
	{
		my $destFile = sprintf( "0x%08X.clumped.%s", $j, $extension );
		my $k = 0;
		my @args;

		push( @args, $destFile );

		for ( $k = 0; $k < $size and $i <= $#fileIds; $k++, $i++  )
		{
			push( @args, @fileIds[$i] );
		}

		merge( @args );
	}

	$j++;
}
elsif ( $mode eq "header" )
{
	my $File = @ARGV[0];

	if ( $File eq "" )
	{
		die( "You must provide a file" )
	}

	my @headerArgs;

	push( @headerArgs, $File ); 

	printf( "Adding magic header to file %s\n", $File );

	header( @headerArgs );
}
else
{
	printUsage;
}
