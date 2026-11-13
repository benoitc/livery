# Ecosystem

Companion libraries built on Livery. Each is a separate hex/git project
with its own docs and releases; use one when you need that service and
want to stay with Livery. They use Livery's own HTTP client and HTTP/2
support, so retries, circuit breakers, middleware, and streaming work
the way you already know.

## livery_grpc

gRPC server and client on top of Livery's HTTP/2 support. You write plain Erlang;
the wire format is generated from your `.proto` files. All four call types
(unary, server-streaming, client-streaming, bidirectional), deadlines,
gRPC-Web, server reflection, and the standard health service.

- Repo: <https://github.com/benoitc/livery_grpc>

## livery_s3

S3-compatible object storage client on the Livery HTTP client. Signs every
request with AWS Signature V4 and works with AWS S3, Garage, MinIO, Ceph,
and Wasabi. Object CRUD, byte ranges, multipart uploads, versioning,
batch delete, and presigned URLs, with credential providers (static, env,
shared config, IMDS, STS/web-identity).

- Repo: <https://github.com/benoitc/livery_s3>

## livery_stripe

Stripe API client on the Livery HTTP client. Covers customers, products,
prices, Checkout, the Billing Portal, subscriptions, payment and setup
intents, invoices, refunds, coupons, and webhook signature verification.

- Repo: <https://github.com/benoitc/livery_stripe>
