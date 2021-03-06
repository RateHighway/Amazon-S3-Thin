package Amazon::S3::Thin;
use 5.008001;
use strict;
use warnings;

use Carp;
use LWP::UserAgent;
use URI::Escape qw(uri_escape_utf8);
use Amazon::S3::Thin::Signer;
use Digest::MD5;
use Encode;

our $VERSION = '0.16';

my $METADATA_PREFIX      = 'x-amz-meta-';

sub new {
    my $class = shift;
    my $self  = shift;

    bless $self, $class;

    die "No aws_access_key_id"     unless $self->{aws_access_key_id};
    die "No aws_secret_access_key" unless $self->{aws_secret_access_key};

    $self->secure(0)                unless defined $self->secure;
    $self->host('s3.amazonaws.com') unless defined $self->host;
    $self->ua($self->_default_ua)   unless defined $self->ua;
    $self->{signature_version} = 4 unless defined $self->{signature_version};

    return $self;
}

sub _default_ua {
    my $self = shift;

    my $ua = LWP::UserAgent->new(
        keep_alive            => 10,
        requests_redirectable => [qw(GET HEAD DELETE PUT)],
        );
    $ua->timeout(30);
    $ua->env_proxy;
    return $ua;
}

# accessor
sub secure {
    my $self = shift;
    if (@_) {
        $self->{secure} = shift;
    } else {
        return $self->{secure};
    }
}

# accessor
sub host {
    my $self = shift;
    if (@_) {
        $self->{host} = shift;
    } else {
        return $self->{host};
    }
}

# accessor
sub ua {
    my $self = shift;
    if (@_) {
        $self->{ua} = shift;
    } else {
        return $self->{ua};
    }
}

sub get_object {
    my ($self, $bucket, $key, $headers) = @_;
    my $request = $self->_compose_request('GET', $self->_uri($bucket, $key), $headers);
    return $self->ua->request($request);
}

sub head_object {
    my ($self, $bucket, $key) = @_;
    my $request = $self->_compose_request('HEAD', $self->_uri($bucket, $key));
    return $self->ua->request($request);
}

sub delete_object {
    my ($self, $bucket, $key) = @_;
    my $request = $self->_compose_request('DELETE', $self->_uri($bucket, $key));
    return $self->ua->request($request);
}

sub copy_object {
    my ($self, $src_bucket, $src_key, $dst_bucket, $dst_key) = @_;
    my $headers = {};
    $headers->{'x-amz-copy-source'} = $src_bucket . "/" . $src_key;
    my $request = $self->_compose_request('PUT', $self->_uri($dst_bucket, $dst_key), $headers);
    return $self->ua->request($request);
}

sub put_object {
    my ($self, $bucket, $key, $content, $headers) = @_;
    croak 'must specify key' unless $key && length $key;

    if ($headers->{acl_short}) {
        $self->_validate_acl_short($headers->{acl_short});
        $headers->{'x-amz-acl'} = $headers->{acl_short};
        delete $headers->{acl_short};
    }

    if (ref($content) eq 'SCALAR') {
        $headers->{'Content-Length'} ||= -s $$content;
        $content = _content_sub($$content);
    }
    else {
        $headers->{'Content-Length'} ||= length $content;
    }

    if (ref($content)) {
        # TODO
        # I do not understand what it is :(
        #
        # return $self->_send_request_expect_nothing_probed('PUT',
        #    $self->_uri($bucket, $key), $headers, $content);
        #
        die "unable to handle reference";
    }
    else {
        my $request = $self->_compose_request('PUT', $self->_uri($bucket, $key), $headers, $content);
        return $self->ua->request($request);
    }
}

sub list_objects {
    my ($self, $bucket, $opt) = @_;
    croak 'must specify bucket' unless $bucket;
    $opt ||= {};

    my $path = $bucket . "/";
    if (%$opt) {
        $path .= "?"
          . join('&',
            map { $_ . "=" . $self->_urlencode($opt->{$_}) } sort keys %$opt);
    }

    my $request = $self->_compose_request('GET', $path);
    my $response = $self->ua->request($request);
    return $response;
}

sub delete_multiple_objects {
    my ($self, $bucket, @keys) = @_;

    my $content = _build_xml_for_delete(@keys);

    my $request = $self->_compose_request(
        'POST',
        "$bucket/?delete",
        {
            'Content-MD5'    => Digest::MD5::md5_base64($content) . '==',
            'Content-Length' => length $content,
        },
        $content
    );
    my $response = $self->ua->request($request);
    return $response;
}

sub _build_xml_for_delete {
    my (@keys) = @_;

    my $content = '<Delete><Quiet>true</Quiet>';

    foreach my $k (@keys) {
        $content .= '<Object><Key>'
                  . Encode::encode('UTF-8', $k)
                  . '</Key></Object>';
    }
    $content .= '</Delete>';

    return $content;
}

sub _uri {
    my ($self, $bucket, $key) = @_;
    return ($key)
      ? $bucket . "/" . $self->_urlencode($key, 1)
      : $bucket . "/";
}

sub _urlencode {
    my ($self, $unencoded, $allow_slash) = @_;
    my $allowed = 'A-Za-z0-9_\-\.';
    $allowed = "$allowed/" if $allow_slash;
    return uri_escape_utf8($unencoded, "^$allowed");
}

sub _validate_acl_short {
    my ($self, $policy_name) = @_;

    if (!grep({$policy_name eq $_}
            qw(private public-read public-read-write authenticated-read)))
    {
        croak "$policy_name is not a supported canned access policy";
    }
}

# EU buckets must be accessed via their DNS name. This routine figures out if
# a given bucket name can be safely used as a DNS name.
sub _is_dns_bucket {
    my ($self, $bucketname) = @_;

    if (length $bucketname > 63) {
        return 0;
    }
    if (length $bucketname < 3) {
        return;
    }
    return 0 unless $bucketname =~ m{^[a-z0-9][a-z0-9.-]+$};
    my @components = split /\./, $bucketname;
    for my $c (@components) {
        return 0 if $c =~ m{^-};
        return 0 if $c =~ m{-$};
        return 0 if $c eq '';
    }
    return 1;
}

# make the HTTP::Request object
sub _compose_request {
    my ($self, $method, $path, $headers, $content, $metadata) = @_;
    croak 'must specify method' unless $method;
    croak 'must specify path'   unless defined $path;
    $headers ||= {};
    $metadata ||= {};

    # generates an HTTP::Headers objects given one hash that represents http
    # headers to set and another hash that represents an object's metadata.
    my $http_headers = HTTP::Headers->new;
    while (my ($k, $v) = each %$headers) {
        $http_headers->header($k => $v);
    }
    while (my ($k, $v) = each %$metadata) {
        $http_headers->header("$METADATA_PREFIX$k" => $v);
    }

    my $protocol = $self->secure ? 'https' : 'http';
    my $host     = $self->host;
    my $url;

    if ($path =~ m{^([^/?]+)(.*)} && $self->_is_dns_bucket($1)) {
        $url = "$protocol://$1.$host$2";
    } else {
        $url = "$protocol://$host/$path";
    }

    my $request = HTTP::Request->new($method, $url, $http_headers, $content);
    $self->_sign($request);
    return $request;
}

# sign the request using the signer, unless already signed
sub _sign
{
  my ($self, $request) = @_;
  my $signer = $self->_signer;
  $signer->sign($request) unless $request->header('Authorization');
}

sub _signer
{
  my $self = shift;
  $self->{signer} ||= Amazon::S3::Thin::Signer->factory($self);
}

1;

__END__

=head1 NAME

Amazon::S3::Thin - A thin, lightweight, low-level Amazon S3 client

=head1 SYNOPSIS

  use Amazon::S3::Thin;

  my $s3client = Amazon::S3::Thin->new(
      {   aws_access_key_id     => $aws_access_key_id,
          aws_secret_access_key => $aws_secret_access_key,
      }
  );

  my $key = "dir/file.txt";
  my $response;
  $response = $s3client->put_object($bucket, $key, "hello world");

  $response = $s3client->get_object($bucket, $key);
  print $response->content; # => "hello world"

  $response = $s3client->delete_object($bucket, $key);

  $response = $s3client->delete_multiple_objects($bucket, @keys);

  $response = $s3client->copy_object($src_bucket, $src_key,
                                     $dst_bucket, $dst_key);

  $response = $s3client->list_objects(
                              $bucket,
                              {prefix => "foo", delimiter => "/"}
                             );

  $response = $s3client->head_object($bucket, $key);

Requests are signed using signature version 4 by default. To use
signature version 2, add a C<signature_version> option:

  my $s3client = Amazon::S3::Thin->new(
      {   aws_access_key_id     => $aws_access_key_id,
          aws_secret_access_key => $aws_secret_access_key,
          signature_version     => 2,
      }
  );

You can also pass any useragent as you like

  my $s3client = Amazon::S3::Thin->new(
      {   aws_access_key_id     => $aws_access_key_id,
          aws_secret_access_key => $aws_secret_access_key,
          ua                    => $any_LWP_copmatible_useragent,
      }
  );

=head1 DESCRIPTION

Amazon::S3::Thin is a thin, lightweight, low-level Amazon S3 client.

It's designed for only ONE purpose: Send a request and get a response.

In detail, it offers the following features:

=over

=item Low Level

It returns an L<HTTP::Response> object so you can easily inspect
what's happening inside, and can handle errors as you like.

=item Low Dependency

It does not require any XML::* modules, so installation is easy;

=item Low Learning Cost

The interfaces are designed to follow S3 official REST APIs.
So it is easy to learn.

=back

=head2 Comparison to precedent modules

There are already some useful modules like L<Amazon::S3>, L<Net::Amazon::S3>
 on CPAN. They provide a "Perlish" interface, which looks pretty
 for Perl programmers, but they also hide low-level behaviors.
For example, the "get_key" method translate HTTP status 404 into C<undef> and
 HTTP 5xx status into exception.

In some situations, it is very important to see the raw HTTP communications.
That's why I made this module.

=head1 CONSTRUCTOR

=head2 new( \%params )

B<Receives:> hashref with options.

B<Returns:> Amazon::S3::Thin object

It can receive the following arguments:

=over 4

=item * C<aws_access_key_id> (B<REQUIRED>) - an access key id
of your credentials.

=item * C<aws_secret_access_key> (B<REQUIRED>) - an secret access key
 of your credentials.

=item * C<region> - region name for version 4 signatures. default is
'us-east-1'.

=item * C<secure> - whether to use https or not. Default is 0 (http).

=item * C<host> - the base host to use. Default is 'I<s3.amazonaws.com>'.

=item * C<ua> - a user agent object, compatible with LWP::UserAgent.
Default is an instance of L<LWP::UserAgent>.

=item * C<signature_version> - AWS signature version to use. Supported values
are 2 and 4. Default is 4.

=item * C<signer> - Custom object for signing requests. It must have a
C<sign> method that accepts an L<HTTP::Request> object and adds the
signature. Default is to construct an object using L<Amazon::S3::Thin::Signer>
C<factory> method. If C<signer> is supplied, C<signature_version> is not used.

=back

=head1 ACCESSORS

The following accessors are provided. You can use them to get/set your
object's attributes.

=head2 secure

Whether to use https (1) or http (0) when connecting to S3.

=head2 host

The base host to use for connecting to S3.

=head2 ua

The user agent used internally to perform requests and return responses.
If you set this attribute, please make sure you do so with an object
compatible with L<LWP::UserAgent> (i.e. providing the same interface).

=head1 METHODS

=head2 get_object( $bucket, $key [, $headers] )

B<Arguments>:

a list of the following items, in order:

=over 3

=item 1. bucket - a string with the bucket

=item 2. key - a string with the key

=item 3. headers (B<optional>) - hashref with extra headr information

=back

B<Returns>: an L<HTTP::Response> object for the request. Use the C<content()>
method on the returned object to read the contents:

    my $res = $s3->get_object( 'my.bucket', 'my/key.ext' );

    if ($res->is_success) {
        my $content = $res->content;
    }

The GET operation retrieves an object from Amazon S3.

For more information, please refer to
L<< Amazon's documentation for GET|http://docs.aws.amazon.com/AmazonS3/latest/API/RESTObjectGET.html >>.

=head2 delete_object( $bucket, $key )

B<Arguments>: a string with the bucket name, and a string with the key name.

B<Returns>: an L<HTTP::Response> object for the request.

The DELETE operation removes the null version (if there is one) of an object
and inserts a delete marker, which becomes the current version of the
object. If there isn't a null version, Amazon S3 does not remove any objects.

Use the response object to see if it succeeded or not.

For more information, please refer to
L<< Amazon's documentation for DELETE|http://docs.aws.amazon.com/AmazonS3/latest/API/RESTObjectDELETE.html >>.

=head2 copy_object( $src_bucket, $src_key, $dst_bucket, $dst_key )

B<Arguments>: a list with source (bucket, key) and destination (bucket, key)

B<Returns>: an L<HTTP::Response> object for the request.

This method is a variation of the PUT operation as described by
Amazon's S3 API. It creates a copy of an object that is already stored
in Amazon S3. This "PUT copy" operation is the same as performing a GET
from the old bucket/key and then a PUT to the new bucket/key.

For more information, please refer to
L<< Amazon's documentation for COPY|http://docs.aws.amazon.com/AmazonS3/latest/API/RESTObjectCOPY.html >>.

=head2 put_object( $bucket, $key, $content [, $headers] )

B<Arguments>:

a list of the following items, in order:

=over 4

=item 1. bucket - a string with the destination bucket

=item 2. key - a string with the destination key

=item 3. content - a string with the content to be uploaded

=item 4. headers (B<optional>) - hashref with extra headr information

=back

B<Returns>: an L<HTTP::Response> object for the request.

The PUT operation adds an object to a bucket. Amazon S3 never adds partial
objects; if you receive a success response, Amazon S3 added the entire
object to the bucket.

For more information, please refer to
L<< Amazon's documentation for PUT|http://docs.aws.amazon.com/AmazonS3/latest/API/RESTObjectPUT.html >>.

=head2 delete_multiple_objects( $bucket, @keys )

B<Arguments>: a string with the bucket name, and an array with all the keys
to be deleted.

B<Returns>: an L<HTTP::Response> object for the request.

The Multi-Object Delete operation enables you to delete multiple objects
(up to 1000) from a bucket using a single HTTP request. If you know the
object keys that you want to delete, then this operation provides a suitable
alternative to sending individual delete requests with C<delete_object()>,
reducing per-request overhead.

For more information, please refer to
L<< Amazon's documentation for DELETE multiple objects|http://docs.aws.amazon.com/AmazonS3/latest/API/multiobjectdeleteapi.html >>.

=head2 list_objects( $bucket [, \%options ] )

B<Arguments>: a string with the bucket name, and (optionally) a hashref
with any of the following options:

=over 4

=item * C<prefix> (I<string>) - only return keys that begin with the
specified prefix. You can use prefixes to separate a bucket into different
groupings of keys, the same way you'd use a folder in a file system.

=item * C<delimiter> (I<string>) - group keys that contain the same string
between the beginning of the key (or after the prefix, if specified) and the
first occurrence of the delimiter.

=item * C<encoding-type> (I<string>) - if set to "url", will encode keys
in the response (useful when the XML parser can't work unicode keys).

=item * C<marker> (I<string>) - specifies the key to start with when listing
objects. Amazon S3 returns object keys in alphabetical order, starting with
the key right after the marker, in order.

=item * C<max-keys> (I<string>) - Sets the maximum number of keys returned
in the response body. You can add this to your request if you want to
retrieve fewer than the default 1000 keys.

=back

B<Returns>: an L<HTTP::Response> object for the request. Use the C<content()>
method on the returned object to read the contents:

This method returns some or all (up to 1000) of the objects in a bucket. Note
that the response might contain fewer keys but will never contain more.
If there are additional keys that satisfy the search criteria but were not
returned because the limit (either 1000 or max-keys) was exceeded, the
response will contain C<< <IsTruncated>true</IsTruncated> >>. To return the
additional keys, see C<marker> above.

For more information, please refer to
L<< Amazon's documentation for REST Bucket GET| http://docs.aws.amazon.com/AmazonS3/latest/API/RESTBucketGET.html >>.

=head1 TODO

lots of APIs are not implemented yet.

=head1 REPOSITORY

L<https://github.com/DQNEO/Amazon-S3-Thin>

=head1 LICENSE

Copyright (C) DQNEO.

This library is free software; you can redistribute it and/or modify
it under the same terms as Perl itself.

=head1 AUTHOR

DQNEO

=head2 THANKS TO

Timothy Appnel
Breno G. de Oliveira

=head1 SEE ALSO

L<Amazon::S3>, L<https://github.com/tima/perl-amazon-s3>

L<Net::Amazon::S3>

L<Amazon S3 API Reference : REST API|http://docs.aws.amazon.com/AmazonS3/latest/API/APIRest.html>

L<Amazon S3 API Reference : List of Error Codes|http://docs.aws.amazon.com/AmazonS3/latest/API/ErrorResponses.html#ErrorCodeList>

=cut
