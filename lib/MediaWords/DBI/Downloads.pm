package MediaWords::DBI::Downloads;
use Modern::Perl "2013";
use MediaWords::CommonLibs;

=head1 NAME

Mediawords::DBI::Downloads - various helper functions for downloads, including storing and fetching content

=head1 SYNOPSIS

    my $download = $db->find_by_id( 'downloads', $downloads_id );

    my $content_ref = MediaWords::DBI::Downloads::fetch_content( $db, $download );

    $$content_ref =~ s/foo/bar/g;

    Mediawords::DBI::Downloads::story_content( $db, $download, $content_ref );

=head1 DESCRIPTION

This module includes various helper function for dealing with downloads.

Most importantly, this module has the store_content and fetch_content functions, which store and fetch content for a
download from the pluggable content store.  The storage module is configured in mediawords.yml by the
mediawords.download_storage_locations setting.  The three choices are databaseinline, which stores the content in the
downloads table; postgres, which stores the content in a separate postgres table and optionally database; and amazon_s3,
which stores the content in amazon_s3.  The default is postgres, and the production system uses amazon_s3.

This module also includes extract and related functions to handle download extraction.

=cut

use strict;
use warnings;

use Carp;
use Scalar::Defer;
use Readonly;

use MediaWords::Crawler::Extractor;
use MediaWords::Util::Config;
use MediaWords::Util::HTML;
use MediaWords::DB;
use MediaWords::DBI::DownloadTexts;
use MediaWords::DBI::Stories;
use MediaWords::StoryVectors;
use MediaWords::Util::Paths;
use MediaWords::Util::ExtractorFactory;
use MediaWords::Util::HeuristicExtractor;
use MediaWords::GearmanFunction::AnnotateWithCoreNLP;
use MediaWords::Util::ThriftExtractor;

# Database inline content length limit
Readonly my $INLINE_CONTENT_LENGTH => 256;

=head1 FUNCTIONS

=cut

# Inline download store
# (downloads.path is prefixed with "content:", download is stored in downloads.path itself)
my $_store_inline = lazy
{
    require MediaWords::KeyValueStore::DatabaseInline;

    return MediaWords::KeyValueStore::DatabaseInline->new();
};

# Amazon S3 download store
# (downloads.path is prefixed with "amazon_s3:", download is stored in Amazon S3)
my $_store_amazon_s3 = lazy
{
    require MediaWords::KeyValueStore::AmazonS3;
    require MediaWords::KeyValueStore::CachedAmazonS3;

    my $config = MediaWords::Util::Config::get_config;

    unless ( $config->{ amazon_s3 } )
    {
        say STDERR "Amazon S3 download store is not configured.";
        return undef;
    }

    my $store_package_name = 'MediaWords::KeyValueStore::AmazonS3';
    my $cache_root_dir     = undef;
    if ( $config->{ mediawords }->{ cache_s3_downloads } eq 'yes' )
    {
        $store_package_name = 'MediaWords::KeyValueStore::CachedAmazonS3';
        $cache_root_dir     = $config->{ mediawords }->{ data_dir } . '/cache/s3_downloads';
    }

    return $store_package_name->new(
        {
            access_key_id     => $config->{ amazon_s3 }->{ downloads }->{ access_key_id },
            secret_access_key => $config->{ amazon_s3 }->{ downloads }->{ secret_access_key },
            bucket_name       => $config->{ amazon_s3 }->{ downloads }->{ bucket_name },
            directory_name    => $config->{ amazon_s3 }->{ downloads }->{ directory_name },
            cache_root_dir    => $cache_root_dir,
        }
    );
};

# PostgreSQL download store
# (downloads.path is prefixed with "postgresql:", download is stored in "raw_downloads" table)
my $_store_postgresql = lazy
{
    require MediaWords::KeyValueStore::PostgreSQL;
    require MediaWords::KeyValueStore::MultipleStores;

    my $config = MediaWords::Util::Config::get_config;

    # Main raw downloads database / table
    my $raw_downloads_db_label = 'raw_downloads';    # as set up in mediawords.yml
    unless ( grep { $_ eq $raw_downloads_db_label } MediaWords::DB::get_db_labels() )
    {
        #say STDERR "No such label '$raw_downloads_db_label', falling back to default database";
        $raw_downloads_db_label = undef;
    }

    my $postgresql_store = MediaWords::KeyValueStore::PostgreSQL->new(
        {
            database_label => $raw_downloads_db_label,                         #
            table => ( $raw_downloads_db_label ? undef : 'raw_downloads' ),    #
        }
    );

    # Add Amazon S3 fallback storage if needed
    if ( lc( $config->{ mediawords }->{ fallback_postgresql_downloads_to_s3 } eq 'yes' ) )
    {
        my $amazon_s3_store = force $_store_amazon_s3;
        unless ( defined $amazon_s3_store )
        {
            croak "'fallback_postgresql_downloads_to_s3' is enabled, but Amazon S3 download storage is not set up.";
        }

        my $postgresql_then_s3_store = MediaWords::KeyValueStore::MultipleStores->new(
            {
                stores_for_reading => [ $postgresql_store, $amazon_s3_store ],
                stores_for_writing => [ $postgresql_store ], # where to write is defined by "download_storage_locations"
            }
        );
        return $postgresql_then_s3_store;
    }
    else
    {
        return $postgresql_store;
    }
};

# (Multi)store for writing downloads
my $_store_for_writing_non_inline_downloads = lazy
{
    require MediaWords::KeyValueStore::MultipleStores;

    my $config = MediaWords::Util::Config::get_config;

    my @stores_for_writing;

    # Early sanity check on configuration
    my $download_storage_locations = $config->{ mediawords }->{ download_storage_locations };
    if ( scalar( @{ $download_storage_locations } ) == 0 )
    {
        croak "No download stores are configured.";
    }

    foreach my $location ( @{ $download_storage_locations } )
    {
        $location = lc( $location );
        my $store;

        if ( $location eq 'databaseinline' )
        {
            croak "$location is not valid for storage";

        }
        elsif ( $location eq 'postgresql' )
        {
            $store = force $_store_postgresql;

        }
        elsif ( $location eq 's3' or $location eq 'amazon_s3' )
        {
            $store = force $_store_amazon_s3;

        }
        else
        {
            croak "Store location '$location' is not valid.";

        }

        unless ( defined $store )
        {
            croak "Store for location '$location' is not configured.";
        }

        push( @stores_for_writing, $store );
    }

    return MediaWords::KeyValueStore::MultipleStores->new( { stores_for_writing => \@stores_for_writing, } );
};

# Returns store for writing new downloads to
sub _download_store_for_writing($)
{
    my $content_ref = shift;

    if ( length( $$content_ref ) < $INLINE_CONTENT_LENGTH )
    {
        return force $_store_inline;
    }
    else
    {
        return force $_store_for_writing_non_inline_downloads;
    }
}

# Returns store to try fetching download from
sub _download_store_for_reading($)
{
    my $download = shift;

    my $download_store;

    my $path = $download->{ path };
    unless ( $path )
    {
        croak "Download path is not set for download $download->{ downloads_id }";
    }

    if ( $path =~ /^([\w]+):/ )
    {
        Readonly my $location => lc( $1 );

        if ( $location eq 'content' )
        {
            $download_store = force $_store_inline;
        }

        elsif ( $location eq 'postgresql' )
        {
            $download_store = force $_store_postgresql;
        }

        elsif ( $location eq 's3' or $location eq 'amazon_s3' )
        {
            $download_store = force $_store_amazon_s3;
        }

        elsif ( $location eq 'gridfs' or $location eq 'tar' )
        {
            # Might get later overriden to "amazon_s3"
            $download_store = force $_store_postgresql;
        }

        else
        {
            croak "Download location '$location' is unknown for download $download->{ downloads_id }";
        }
    }
    else
    {
        # Assume it's stored in a filesystem (the downloads.path contains a
        # full path to the download).
        #
        # Those downloads have been migrated to PostgreSQL (which might get redirected to S3).
        $download_store = force $_store_postgresql;
    }

    unless ( defined $download_store )
    {
        croak "Download store is undefined for download " . $download->{ downloads_id };
    }

    my $config = MediaWords::Util::Config::get_config;

    # All non-inline downloads have to be fetched from S3?
    if ( $download_store ne force $_store_inline
        and lc( $config->{ mediawords }->{ read_all_downloads_from_s3 } ) eq 'yes' )
    {
        $download_store = force $_store_amazon_s3;
    }

    unless ( $download_store )
    {
        croak "Download store is not configured for download " . $download->{ downloads_id };
    }

    return $download_store;
}

=head2 fetch_content( $db, $download )

Fetch the content for the given download as a content_ref from the configured content store.

=cut

sub fetch_content($$)
{
    my ( $db, $download ) = @_;

    unless ( exists $download->{ downloads_id } )
    {
        croak "fetch_content called with invalid download";
    }

    unless ( download_successful( $download ) )
    {
        confess "attempt to fetch content for unsuccessful download $download->{ downloads_id }  / $download->{ state }";
    }

    my $store = _download_store_for_reading( $download );
    unless ( $store )
    {
        croak "No store for reading download " . $download->{ downloads_id };
    }

    # Fetch content
    my $content_ref = $store->fetch_content( $db, $download->{ downloads_id }, $download->{ path } );
    unless ( $content_ref and ref( $content_ref ) eq 'SCALAR' )
    {
        croak "Unable to fetch content for download " . $download->{ downloads_id } . "; tried store: " . ref( $store );
    }

    # horrible hack to fix old content that is not stored in unicode
    my $config                  = MediaWords::Util::Config::get_config;
    my $ascii_hack_downloads_id = $config->{ mediawords }->{ ascii_hack_downloads_id };
    if ( $ascii_hack_downloads_id and ( $download->{ downloads_id } < $ascii_hack_downloads_id ) )
    {
        $$content_ref =~ s/[^[:ascii:]]/ /g;
    }

    return $content_ref;
}

=head2 store_content( $db, $download, $content_ref )

Store the download content in the configured content store.

=cut

sub store_content($$$)
{
    my ( $db, $download, $content_ref ) = @_;

    #say STDERR "starting store_content for download $download->{ downloads_id } ";

    my $new_state = 'success';
    if ( $download->{ state } eq 'feed_error' )
    {
        $new_state = $download->{ state };
    }

    # Store content
    my $path = '';
    eval {
        my $store = _download_store_for_writing( $content_ref );
        unless ( defined $store )
        {
            croak "No download store to write to.";
        }

        $path = $store->store_content( $db, $download->{ downloads_id }, $content_ref );
    };
    if ( $@ )
    {
        croak "Error while trying to store download ID " . $download->{ downloads_id } . ':' . $@;
        $new_state = 'error';
        $download->{ error_message } = $@;
    }
    elsif ( $new_state eq 'success' )
    {
        $download->{ error_message } = '';
    }

    # Update database
    $db->query(
        <<"EOF",
        UPDATE downloads
        SET state = ?,
            path = ?,
            error_message = ?,
            file_status = DEFAULT       -- Reset the file_status in case
                                        -- this download is being redownloaded
        WHERE downloads_id = ?
EOF
        $new_state,
        $path,
        $download->{ error_message },
        $download->{ downloads_id }
    );

    $download->{ state } = $new_state;
    $download->{ path }  = $path;

    $download = $db->find_by_id( 'downloads', $download->{ downloads_id } );

    return $download;
}

# return content as lines in an array after running through the extractor preprocessor.  this is only used by the
# heuristic extractor.
sub _preprocess_content_lines($)
{
    my ( $content_ref ) = @_;

    my $lines = [ split( /[\n\r]+/, $$content_ref ) ];

    $lines = MediaWords::Crawler::Extractor::preprocess( $lines );

    return $lines;
}

=head2 fetch_preprocessed_content_lines( $db, $download )

Fetch the content as lines in an array after running through the extractor preprocessor. This is only used by the
heuristic extractor.

=cut

sub fetch_preprocessed_content_lines($$)
{
    my ( $db, $download ) = @_;

    my $content_ref = fetch_content( $db, $download );

    unless ( $content_ref )
    {
        warn( "unable to find content: " . $download->{ downloads_id } );
        return [];
    }

    return _preprocess_content_lines( $content_ref );
}

=head2 extract( $db, $download )

Run the extractor against the download content and return a hash in the form of:

    { extracted_html => $html,    # a string with the extracted html
      extracted_text => $text,    # a string with the extracted html strippped to text
      download_lines => $lines,   # (optional) an array of the lines of original html
      scores => $scores }         # (optional) the scores returned by Mediawords::Crawler::Extractor::score_lines

The extractor used is configured in mediawords.yml by mediawords.extractor_method, which should be one of
'HeuristicExtractor' or 'PythonReadability'.

=cut

sub extract($$)
{
    my ( $db, $download ) = @_;

    my $content_ref = fetch_content( $db, $download );

    # FIXME if we're using Readability extractor, there's no point fetching
    # story title and description as Readability doesn't use it
    my $story = $db->find_by_id( 'stories', $download->{ stories_id } );

    return _extract_content_ref( $content_ref, $story->{ title }, $story->{ description } );
}

# forbes is putting all of its content into a javascript variable, causing our extractor to fall down.
# this function replaces $$content_ref with the html assigned to the javascript variable.
# return true iff the function is able to find and parse the javascript content
sub _parse_out_javascript_content
{
    my ( $content_ref ) = @_;

    if ( $$content_ref =~ s/.*fbs_settings.content[^\}]*body\"\:\"([^"\\]*(\\.[^"\\]*)*)\".*/$1/ms )
    {
        $$content_ref =~ s/\\[rn]/ /g;
        $$content_ref =~ s/\[\w+ [^\]]*\]//g;

        return 1;
    }

    return 0;
}

# given the list of all lines from an html file and a list of the line numbers of lines to be included
# in the extracted text, return a single string consisting of the extracted html.  take care to add new lines
# around block level tags so that we setup the html string to maintain the default double newline sentence boundaries.
# this function is only used for extraction via the heuristic extractor.
sub _get_extracted_html
{
    my ( $lines, $included_lines ) = @_;

    my $is_line_included = { map { $_ => 1 } @{ $included_lines } };

    my $config = MediaWords::Util::Config::get_config;

    my $extracted_html = '';

    # This variable is used to make sure we don't add unnecessary double newlines
    my $previous_concated_line_was_story = 0;

    for ( my $i = 0 ; $i < @{ $lines } ; $i++ )
    {
        if ( $is_line_included->{ $i } )
        {
            my $line_text;

            $previous_concated_line_was_story = 1;

            $line_text = $lines->[ $i ];

            $extracted_html .= ' ' . $line_text;
        }
        elsif ( MediaWords::Util::HTML::contains_block_level_tags( $lines->[ $i ] ) )
        {
            ## '\n\n\ is used as a sentence splitter so no need to add it more than once between text lines
            if ( $previous_concated_line_was_story )
            {

                # Add double newline bc/ it will be recognized by the sentence splitter as a sentence boundary.
                $extracted_html .= "\n\n";

                $previous_concated_line_was_story = 0;
            }
        }
    }

    return $extracted_html;
}

# call configured extractor on the content_ref
sub _call_extractor_on_html($$$;$)
{
    my ( $content_ref, $story_title, $story_description, $extractor_method ) = @_;

    my $ret;
    my $extracted_html;

    if ( $extractor_method eq 'PythonReadability' )
    {
        $extracted_html = MediaWords::Util::ThriftExtractor::get_extracted_html( $$content_ref );
    }
    elsif ( $extractor_method eq 'HeuristicExtractor' )
    {
        my $lines = _preprocess_content_lines( $content_ref );

        # print "PREPROCESSED LINES:\n**\n" . join( "\n", @{ $lines } ) . "\n**\n";

        $ret = extract_preprocessed_lines_for_story( $lines, $story_title, $story_description );

        my $download_lines        = $ret->{ download_lines };
        my $included_line_numbers = $ret->{ included_line_numbers };

        $extracted_html = _get_extracted_html( $download_lines, $included_line_numbers );
    }
    else
    {
        die "invalid extractor method: $extractor_method";
    }

    my $extracted_text = html_strip( $extracted_html );

    $ret->{ extracted_html } = $extracted_html;
    $ret->{ extracted_text } = $extracted_text;

    return $ret;
}

# extract content referenced by $content_ref
sub _extract_content_ref($$$;$)
{
    my ( $content_ref, $story_title, $story_description, $extractor_method ) = @_;

    unless ( $extractor_method )
    {
        my $config = MediaWords::Util::Config::get_config;
        $extractor_method = $config->{ mediawords }->{ extractor_method };
    }

    my $extracted_html;
    my $ret = {};

    # Don't run through expensive extractor if the content is short and has no html
    if ( ( length( $$content_ref ) < 4096 ) and ( $$content_ref !~ /\<.*\>/ ) )
    {
        $ret = {
            extracted_html => $$content_ref,
            extracted_text => $$content_ref,
        };
    }
    else
    {
        $ret = _call_extractor_on_html( $content_ref, $story_title, $story_description, $extractor_method );

        # if we didn't get much text, try looking for content stored in the javascript
        if ( ( length( $ret->{ extracted_text } ) < 256 ) && _parse_out_javascript_content( $content_ref ) )
        {
            my $js_ret = _call_extractor_on_html( $content_ref, $story_title, $story_description, $extractor_method );

            $ret = $js_ret if ( length( $js_ret->{ extracted_text } ) > length( $ret->{ extracted_text } ) );
        }

    }

    return $ret;
}

=head2 extract_preprocessed_lines_for_story( $lines, $story_title, $story_description )

Preprocess content lines and send through heuristic extractor.

=cut

sub extract_preprocessed_lines_for_story($$$)
{
    my ( $lines, $story_title, $story_description ) = @_;

    my $old_extractor = MediaWords::Util::ExtractorFactory::createExtractor();

    return $old_extractor->extract_preprocessed_lines_for_story( $lines, $story_title, $story_description );
}

=head2 extract_and_create_download_text( $db, $download )

Extract the download and create a download_text from the extracted download.

=cut

sub extract_and_create_download_text( $$ )
{
    my ( $db, $download ) = @_;

    my $extract = extract( $db, $download );

    my $download_text = MediaWords::DBI::DownloadTexts::create( $db, $download, $extract );

    return $download_text;
}

=head2 process_download_for_extractor( $db, $download, $process_num, $no_dedup_sentences, $no_vector )

Extract the download create the resulting download_text entry.  If there are no remaining downloads to be extracted
for the story, call MediaWords::DBI::Stories::process_extracted_story() on the parent story.

=cut

sub process_download_for_extractor($$$;$$$)
{
    my ( $db, $download, $process_num, $no_dedup_sentences, $no_vector ) = @_;

    $process_num //= 1;

    my $stories_id = $download->{ stories_id };

    say STDERR "[$process_num] extract: $download->{ downloads_id } $stories_id $download->{ url }";
    my $download_text = MediaWords::DBI::Downloads::extract_and_create_download_text( $db, $download );

    my $has_remaining_download = $db->query( <<SQL, $stories_id )->hash;
SELECT downloads_id FROM downloads WHERE stories_id = ? AND extracted = 'f' AND type = 'content'
SQL

    if ( !$has_remaining_download )
    {
        my $story = $db->find_by_id( 'stories', $stories_id );

        MediaWords::DBI::Stories::process_extracted_story( $story, $db, $no_dedup_sentences, $no_vector );
    }
    elsif ( !( $no_vector ) )
    {
        say STDERR "[$process_num] pending more downloads ...";
    }
}

=head2 process_download_for_extractor_and_record_error( $db, $download, $process_num )

Call process_download_for_extractor.  Catch any error in an eval{} and store the error message in the "downloads" table.

=cut

sub process_download_for_extractor_and_record_error
{
    my ( $db, $download, $process_num ) = @_;

    my $no_dedup_sentences = 0;
    my $no_vector          = 0;

    eval { process_download_for_extractor( $db, $download, $process_num, $no_dedup_sentences, $no_vector ); };

    if ( $@ )
    {
        my $downloads_id = $download->{ downloads_id };

        say STDERR "extractor error processing download $downloads_id: $@";

        $db->rollback;

        $db->query( <<SQL, "extractor error: $@", $downloads_id );
UPDATE downloads SET state = 'extractor_error', error_message = ? WHERE downloads_id = ?
SQL

        $db->commit;

        return 0;
    }

    # Extraction succeeded
    $db->commit;

    return 1;
}

=head2 download_successful( $download )

Return true if the download was downloaded successfully.
This method is needed because there are cases it which the download was sucessfully downloaded
but had a subsequent processing error. e.g. 'extractor_error' and 'feed_error'

=cut

sub download_successful
{
    my ( $download ) = @_;

    my $state = $download->{ state };

    return ( $state eq 'success' ) || ( $state eq 'feed_error' ) || ( $state eq 'extractor_error' );
}

=head2 get_media_id( $db, $download )

Convenience method to get the media_id for the download.

=cut

sub get_media_id($$)
{
    my ( $db, $download ) = @_;

    return $db->query( "select media_id from feeds where feeds_id = ?", $download->{ feeds_id } )->hash->{ media_id };
}

=head2 get_medium( $db, $download )

Convenience method to get the media source for the given download

=cut

sub get_medium($$)
{
    my ( $db, $download ) = @_;

    return $db->query( <<SQL, $download->{ feeds_id } )->hash;
select m.* from feeds f join media m on ( f.media_id = m.media_id ) where feeds_id = ?
SQL
}

1;
