import { Duration, LegacyStackSynthesizer, RemovalPolicy, Stack, StackProps, CfnOutput, Token } from 'aws-cdk-lib';
import * as acm from 'aws-cdk-lib/aws-certificatemanager';
import * as cloudfront from 'aws-cdk-lib/aws-cloudfront';
import * as origins from 'aws-cdk-lib/aws-cloudfront-origins';
import * as iam from 'aws-cdk-lib/aws-iam';
import * as route53 from 'aws-cdk-lib/aws-route53';
import * as targets from 'aws-cdk-lib/aws-route53-targets';
import * as s3 from 'aws-cdk-lib/aws-s3';
import { Construct } from 'constructs';
import * as c from './config';

export interface SiteStackProps extends Omit<StackProps, 'synthesizer'> {
  config: c.SiteConfig;
  /** ARN of the account's EXISTING GitHub OIDC provider. This stack never creates one. */
  oidcProviderArn: string;
  /** Dummy-synth only (tests): skips the hosted zone lookup. Real deploys look the zone up by name. */
  hostedZoneId?: string;
}

/**
 * Strict CSP. The site fetches nothing, so there is no connect-src (default-src 'none' covers it). Pages must use
 * external scripts and styles from the same origin: inline <style>/<script> are blocked.
 */
export const CONTENT_SECURITY_POLICY = [
  "default-src 'none'",
  "script-src 'self'",
  "style-src 'self'",
  "img-src 'self'",
  "base-uri 'none'",
  "form-action 'none'",
  "frame-ancestors 'none'",
  "object-src 'none'",
].join('; ');

export const PERMISSIONS_POLICY = 'camera=(), microphone=(), geolocation=(), payment=(), usb=()';
export const NONCURRENT_VERSION_DAYS = 365;
export const ERROR_TTL = Duration.seconds(10);

/**
 * Viewer-request function (cloudfront-js-2.0): `/x/` -> `/x/index.html`. The site is prerendered, so this is the only
 * rewrite.
 */
export const ROUTER_SOURCE = `function handler(event) {
  var r = event.request;
  var uri = r.uri;
  if (uri.charAt(uri.length - 1) === '/') r.uri = uri + 'index.html';
  return r;
}
`;

/** Private S3 bucket + CloudFront (OAC) for the site domain, plus the role the buildrules publish workflow assumes. */
export class SiteStack extends Stack {
  readonly bucket: s3.Bucket;
  readonly distribution: cloudfront.Distribution;
  readonly publishRole: iam.Role;

  constructor(scope: Construct, props: SiteStackProps) {
    // No assets, so no cdk bootstrap is needed; the admin deploys with their own credentials.
    super(scope, c.SITE_STACK_NAME, { ...props, synthesizer: new LegacyStackSynthesizer() });
    if (!Token.isUnresolved(this.region) && this.region !== c.REGION) {
      throw new Error(`must be deployed to ${c.REGION}; got ${this.region}`);
    }
    if (!/^arn:aws:iam::\d{12}:oidc-provider\/token\.actions\.githubusercontent\.com$/.test(props.oidcProviderArn)) {
      throw new Error('oidcProviderArn must be the ARN of the account GitHub OIDC provider');
    }

    this.bucket = new s3.Bucket(this, 'Bucket', {
      bucketName: c.bucketName(this.account),
      blockPublicAccess: s3.BlockPublicAccess.BLOCK_ALL,
      encryption: s3.BucketEncryption.S3_MANAGED,
      versioned: true,
      enforceSSL: true,
      objectOwnership: s3.ObjectOwnership.BUCKET_OWNER_ENFORCED,
      removalPolicy: RemovalPolicy.RETAIN,
      lifecycleRules: [
        {
          // Only superseded versions expire (365 days, so a replaced page stays recoverable for a year).
          // Current objects are kept forever.
          id: 'expire-noncurrent-versions',
          noncurrentVersionExpiration: Duration.days(NONCURRENT_VERSION_DAYS),
          abortIncompleteMultipartUploadAfter: Duration.days(7),
        },
      ],
    });

    const domain = props.config.domain;
    const zone = props.hostedZoneId
      ? route53.HostedZone.fromHostedZoneAttributes(this, 'Zone', { hostedZoneId: props.hostedZoneId, zoneName: domain })
      : route53.HostedZone.fromLookup(this, 'Zone', { domainName: domain });
    const cert = new acm.Certificate(this, 'Cert', {
      domainName: domain,
      validation: acm.CertificateValidation.fromDns(zone),
    });

    const headers = new cloudfront.ResponseHeadersPolicy(this, 'Headers', {
      responseHeadersPolicyName: c.HEADERS_POLICY_NAME,
      securityHeadersBehavior: {
        contentSecurityPolicy: { contentSecurityPolicy: CONTENT_SECURITY_POLICY, override: true },
        contentTypeOptions: { override: true },
        strictTransportSecurity: { accessControlMaxAge: Duration.days(730), includeSubdomains: true, override: true },
        frameOptions: { frameOption: cloudfront.HeadersFrameOption.DENY, override: true },
        referrerPolicy: { referrerPolicy: cloudfront.HeadersReferrerPolicy.NO_REFERRER, override: true },
      },
      customHeadersBehavior: {
        customHeaders: [
          { header: 'Cross-Origin-Opener-Policy', value: 'same-origin', override: true },
          { header: 'Cross-Origin-Resource-Policy', value: 'same-origin', override: true },
          { header: 'Permissions-Policy', value: PERMISSIONS_POLICY, override: true },
        ],
      },
    });

    const router = new cloudfront.Function(this, 'Router', {
      functionName: c.ROUTER_NAME,
      comment: 'buildrules site: /x/ -> /x/index.html',
      runtime: cloudfront.FunctionRuntime.JS_2_0,
      code: cloudfront.FunctionCode.fromInline(ROUTER_SOURCE),
    });

    // OAC has no ListBucket, so a missing key answers 403; both get the 404 page with status 404.
    const notFound = (httpStatus: number): cloudfront.ErrorResponse => ({
      httpStatus,
      responseHttpStatus: 404,
      responsePagePath: '/404.html',
      ttl: ERROR_TTL,
    });

    this.distribution = new cloudfront.Distribution(this, 'Distribution', {
      comment: `${domain} site`,
      domainNames: [domain],
      certificate: cert,
      defaultRootObject: 'index.html',
      minimumProtocolVersion: cloudfront.SecurityPolicyProtocol.TLS_V1_2_2021,
      httpVersion: cloudfront.HttpVersion.HTTP2_AND_3,
      errorResponses: [notFound(403), notFound(404)],
      defaultBehavior: {
        origin: origins.S3BucketOrigin.withOriginAccessControl(this.bucket),
        viewerProtocolPolicy: cloudfront.ViewerProtocolPolicy.REDIRECT_TO_HTTPS,
        allowedMethods: cloudfront.AllowedMethods.ALLOW_GET_HEAD,
        cachePolicy: cloudfront.CachePolicy.CACHING_OPTIMIZED,
        responseHeadersPolicy: headers,
        functionAssociations: [{ function: router, eventType: cloudfront.FunctionEventType.VIEWER_REQUEST }],
      },
    });

    const target = route53.RecordTarget.fromAlias(new targets.CloudFrontTarget(this.distribution));
    new route53.ARecord(this, 'ARecord', { zone, recordName: domain, target });
    new route53.AaaaRecord(this, 'AaaaRecord', { zone, recordName: domain, target });

    // The publish role: assumed by the buildrules reusable workflow only. No CDK, no bootstrap roles, no IAM.
    this.publishRole = new iam.Role(this, 'PublishRole', {
      roleName: c.ROLE_NAME,
      description: 'buildrules site-publish workflow: uploads to the buildrules.dev bucket and invalidates its distribution',
      maxSessionDuration: Duration.hours(1),
      assumedBy: new iam.FederatedPrincipal(
        props.oidcProviderArn,
        {
          StringEquals: {
            [`${c.GITHUB_OIDC_HOST}:aud`]: c.OIDC_AUDIENCE,
            [`${c.GITHUB_OIDC_HOST}:sub`]: c.oidcSubject(props.config),
          },
        },
        'sts:AssumeRoleWithWebIdentity',
      ),
    });
    this.publishRole.addToPolicy(
      new iam.PolicyStatement({
        sid: 'ListBucket',
        actions: ['s3:ListBucket'],
        resources: [this.bucket.bucketArn],
      }),
    );
    this.publishRole.addToPolicy(
      new iam.PolicyStatement({
        sid: 'PutObjects',
        actions: ['s3:PutObject'],
        resources: [this.bucket.arnForObjects('*')],
      }),
    );
    this.publishRole.addToPolicy(
      new iam.PolicyStatement({
        sid: 'DeleteObjects',
        actions: ['s3:DeleteObject'],
        resources: [this.bucket.arnForObjects('*')],
      }),
    );
    this.publishRole.addToPolicy(
      new iam.PolicyStatement({
        sid: 'Invalidate',
        actions: ['cloudfront:CreateInvalidation'],
        resources: [`arn:aws:cloudfront::${this.account}:distribution/${this.distribution.distributionId}`],
      }),
    );

    new CfnOutput(this, 'BucketName', { value: this.bucket.bucketName });
    new CfnOutput(this, 'DistributionId', { value: this.distribution.distributionId });
    new CfnOutput(this, 'PublishRoleArn', { value: this.publishRole.roleArn });
  }
}
