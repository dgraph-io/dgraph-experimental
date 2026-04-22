# Dgraph on Fly.io Deployment Guide

This guide walks you through deploying a single-node Dgraph cluster on [Fly.io](https://fly.io) using the provided `fly.toml` configuration.

## Prerequisites

### 1. Create a Fly.io Account

1. Visit [fly.io](https://fly.io) and sign up for an account
2. Install the Fly CLI by following the [installation guide](https://fly.io/docs/hands-on/install-flyctl/)
3. Authenticate with Fly.io:
   ```bash
   flyctl auth login
   ```

### 2. Verify Installation

Check that flyctl is properly installed:
```bash
flyctl version
```

## Configuration

### 1. Update the App Name

Edit the `fly.toml` file and change the app name:
```toml
app = "your-dgraph-app-name"
```

**Important:** The app name must be globally unique across all Fly.io applications. Your Dgraph instance will be accessible at `https://your-dgraph-app-name.fly.dev`.

### 2. Security Configuration

**Critical:** Change the security token in the `DGRAPH_ALPHA_SECURITY` environment variable:
```toml
DGRAPH_ALPHA_SECURITY = "token=your-secure-random-token;whitelist=0.0.0.0/0"
```

Replace `your-secure-random-token` with a strong, randomly generated token. This token will be required in the `X-Dgraph-AuthToken` header for any requests to the `/alter` endpoint.

#### Adjust Volume Settings
Modify the volume configuration based on your needs:
- `initial_size`: Starting volume size (default: 10GB)
- `auto_extend_size_threshold`: Percentage threshold for auto-extension (default: 80%)
- `auto_extend_size_increment`: Size to add when extending (default: 2GB)
- `auto_extend_size_limit`: Maximum volume size (default: 20GB)

## Deployment

### 1. Deploy the Application

From the directory containing `fly.toml`:
```bash
flyctl deploy
```

### 2. Monitor Deployment

Check the deployment status:
```bash
flyctl status
```

View logs:
```bash
flyctl logs
```

### 3. Assign IP Address

To ensure direct access and simplify health checks, assign a dedicated IP address:
```bash
flyctl ips allocate-v4
```

### 4. Verify Health

Check if your Dgraph instance is healthy using the allocated IP address. You can find your IP with `flyctl ips list`.

```bash
curl http://[your-allocated-ip]:8080/health
```

## Accessing Your Dgraph Instance

### HTTP/GraphQL Endpoint
- **URL:** `https://your-dgraph-app-name.fly.dev`
- **Port:** 443 (HTTPS)
- **Protocols:** DQL queries, GraphQL requests

### gRPC Endpoint
- **URL:** `your-dgraph-app-name.fly.dev:9080`
- **Port:** 9080
- **Protocol:** gRPC over TLS

### Authentication

For admin operations (schema changes, mutations to reserved predicates), include the auth token:
```bash
curl -H "X-Dgraph-AuthToken: your-secure-random-token" \
     -X POST \
     https://your-dgraph-app-name.fly.dev/alter \
     -d '{"drop_all": true}'
```

## Management Commands

### Scale the Application
```bash
flyctl scale count 1
```

### Update Environment Variables
```bash
flyctl secrets set DGRAPH_ALPHA_SECURITY="token=new-token;whitelist=0.0.0.0/0"
```

### View Volume Information
```bash
flyctl volumes list
```

### SSH into the Instance
```bash
flyctl ssh console
```

## Troubleshooting

### Common Issues

1. **App name already taken**
   - Change the `app` name in `fly.toml` to something unique

2. **Health check failures**
   - Check logs with `flyctl logs`
   - Verify the Dgraph process is running: `flyctl ssh console` then `ps aux | grep dgraph`

3. **Connection issues**
   - Ensure your app is deployed: `flyctl status`
   - Check if the health endpoint responds: `curl https://your-app.fly.dev/health`

4. **Volume issues**
   - List volumes: `flyctl volumes list`
   - Check volume usage: `flyctl ssh console` then `df -h /dgraph`

### Useful Commands

```bash
# Restart the application
flyctl apps restart your-dgraph-app-name

# View machine details
flyctl machine list

# Check resource usage
flyctl machine status

# Destroy the application (careful!)
flyctl apps destroy your-dgraph-app-name
```

## Architecture Details

This configuration deploys:
- **Dgraph Zero**: Cluster management (internal)
- **Dgraph Alpha**: Data storage and query processing
- **Persistent Volume**: 10GB initial size with auto-extension
- **TLS Termination**: Automatic HTTPS via Fly.io
- **Health Checks**: HTTP health checks every 10 seconds

## Security Considerations

1. **Change the default token** in `DGRAPH_ALPHA_SECURITY`
2. **Whitelist configuration**: Currently set to `0.0.0.0/0` (all IPs). Consider restricting to specific IP ranges for production
3. **TLS**: All connections are automatically encrypted via Fly.io's TLS termination
4. **Network isolation**: The Dgraph instance runs in Fly.io's private network

## Cost Considerations

- **Compute**: Fly.io charges based on machine usage
- **Storage**: Volume storage is billed separately
- **Bandwidth**: Outbound data transfer charges may apply
- **Always-on**: `auto_stop_machines = false` keeps the instance running continuously

For current pricing, visit [Fly.io Pricing](https://fly.io/docs/about/pricing/).

## Next Steps

1. **Load your schema**: Use the `/alter` endpoint with your auth token
2. **Import data**: Use mutations or bulk loading
3. **Set up monitoring**: Consider integrating with Fly.io's monitoring tools
4. **Backup strategy**: Implement regular backups of your volume data

## Resources

- [Fly.io Documentation](https://fly.io/docs/)
- [Dgraph Documentation](https://dgraph.io/docs/)
- [Dgraph Docker Images](https://hub.docker.com/r/dgraph/standalone)
- [Fly.io Community Forum](https://community.fly.io/)