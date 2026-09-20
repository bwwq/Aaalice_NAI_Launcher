class S3BackendConfig {
  S3BackendConfig({
    required this.endpoint,
    required this.bucket,
    this.region = 'us-east-1',
    this.namespace = 'aaalice-sync',
    this.pathStyle = true,
    this.allowInsecureHttp = false,
  }) {
    if (!endpoint.hasAuthority ||
        endpoint.userInfo.isNotEmpty ||
        endpoint.hasQuery ||
        endpoint.hasFragment ||
        !(endpoint.scheme == 'https' ||
            (allowInsecureHttp && endpoint.scheme == 'http'))) {
      throw const FormatException(
        'Invalid S3 endpoint; HTTPS is required unless HTTP is explicitly enabled.',
      );
    }
    if (!RegExp(r'^[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]$').hasMatch(bucket) ||
        bucket.contains('..') ||
        !RegExp(r'^[a-z0-9-]+$').hasMatch(region)) {
      throw const FormatException('Invalid S3 bucket or region.');
    }
    if (namespace.isEmpty ||
        namespace.split('/').any((p) => p.isEmpty || p == '.' || p == '..') ||
        namespace.contains('\\')) {
      throw const FormatException('Invalid S3 backup prefix.');
    }
  }

  final Uri endpoint;
  final String bucket;
  final String region;
  final String namespace;
  final bool pathStyle;
  final bool allowInsecureHttp;

  Uri uri({String? key, Map<String, String>? query}) {
    final segments = [
      ...endpoint.pathSegments.where((p) => p.isNotEmpty),
      if (pathStyle) bucket,
      if (key != null) ...key.split('/'),
    ];
    return endpoint.replace(
      host: pathStyle ? endpoint.host : '$bucket.${endpoint.host}',
      pathSegments: segments,
      queryParameters: query,
    );
  }
}
