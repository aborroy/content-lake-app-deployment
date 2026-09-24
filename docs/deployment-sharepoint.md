# SharePoint Connector - Deployment and Demo Site Setup

This document describes how to set up and test the SharePoint Online connector against both the
mock Graph service and a real Microsoft 365 tenant.

## Table of Contents

- [Mock Graph Service](#mock-graph-service)
- [Demo Site Structure](#demo-site-structure)
- [Setting Up a Real SharePoint Site](#setting-up-a-real-sharepoint-site)
- [Connector Configuration](#connector-configuration)
- [Running Tests](#running-tests)

---

## Mock Graph Service

The SharePoint connector ships with a mock Microsoft Graph service that runs without requiring a
Microsoft 365 tenant. The mock (`mock-graph`) serves Graph API responses from fixture files and
is used by the end-to-end test suite.

### Why the Mock Exists

Registering an Entra ID application is disabled in this tenant, and SharePoint sites where a developer
is only a member return truncated ACLs that cannot validate permission mapping. The mock allows:

- Building and demonstrating the connector without tenant access
- Testing ACL mapping with known permission fixtures
- Verifying paging, delta feeds, and throttling behavior
- Running the full E2E suite against a known, reproducible structure

### What the Mock Faithfully Reproduces

The mock is designed to catch connector bugs that would only surface against the real Graph API:

1. **Opaque @odata.nextLink paging** - $skip is ignored, just like Graph
2. **302 redirect for /content** - Downloads go through pre-authenticated URLs
3. **410 Gone for expired delta tokens** - Delta sync can expire and require full re-sync
4. **Preference-Applied headers** - Only honoured preferences are listed

### Running the Mock

```bash
# Start with demo stack
cd content-lake-app-deployment
CONNECTOR_SYNC_USERNAME=admin CONNECTOR_SYNC_PASSWORD=admin \
CONNECTOR_SOURCE_TYPE=sharepoint SHAREPOINT_AUTH_MODE=static-token \
SHAREPOINT_ACCESS_TOKEN=mock-token SHAREPOINT_CLIENT_ID=mock \
SHAREPOINT_DRIVE_IDS='b!mock-drive-id' \
SHAREPOINT_GRAPH_BASE_URL=http://mock-graph:8099/v1.0 \
SHAREPOINT_RESOURCE_UNITS_PER_MINUTE=0 \
  docker compose --profile alfresco --profile connector --profile sharepoint-mock up -d

# The mock is accessible at localhost:8099
curl -s http://localhost:8099/mock-diagnostics/requests | jq .
```

---

## Demo Site Structure

The mock's fixture tree contains **8 documents** in **7 containers** (folders), designed to test
all major connector features: permissions, scoping, MIME filtering, delta sync, and ACL mapping.

### Folder Structure

```
drive root (b!mock-drive-id:root)
├── f-public/           (Public folder - everyone can read)
│   ├── quarterly-review.txt       (Plain text, sentence "pangolin-ledger-quarterly")
│   ├── incident-log.txt           (Plain text, sentence "pangolin-ledger-incident")
│   ├── obsolete-note.txt          (Plain text, deleted in delta change #1)
│   └── quarterly-report.pdf       (PDF, sentence "pangolin-ledger-pdf-report")
├── f-user/             (User-scoped folder - only named user)
│   └── named-grant.txt            (Plain text, sentence "pangolin-ledger-user")
├── f-group/            (Group-scoped folder - only group members)
│   └── group-only.txt             (Plain text, sentence "pangolin-ledger-group")
├── f-orglink/          (Organisation link folder - everyone in tenant)
│   └── org-wide.txt               (Plain text, sentence "pangolin-ledger-orgwide")
└── f-nested/           (Nested folder structure)
    └── f-level-two/
        └── deep-file.txt          (Plain text, sentence "pangolin-ledger-nested")
```

### Document Details

| File Name | Item ID | MIME Type | Size | Sentinel Phrase | Permission Scope |
|-----------|---------|-----------|------|-----------------|------------------|
| quarterly-review.txt | i-quarterly | text/plain | 74 | pangolin-ledger-quarterly | Public |
| incident-log.txt | i-incident | text/plain | 75 | pangolin-ledger-incident | Public |
| quarterly-report.pdf | i-report | application/pdf | 649 | pangolin-ledger-pdf-report | Public |
| obsolete-note.txt | i-removed | text/plain | 94 | pangolin-ledger-removed | Public (deleted) |
| named-grant.txt | i-named | text/plain | 77 | pangolin-ledger-user | User-scoped |
| group-only.txt | i-group | text/plain | 74 | pangolin-ledger-group | Group-scoped |
| org-wide.txt | i-orgwide | text/plain | 76 | pangolin-ledger-orgwide | Organisation link |
| deep-file.txt | i-deep | text/plain | 85 | pangolin-ledger-nested | Public (nested) |

### Sentinel Phrases

Each document contains a unique "pangolin-ledger-*" phrase used by tests to verify:
- The document was indexed
- Text extraction worked correctly
- Search returns the expected results
- ACL filtering is applied correctly

### Permission Scenarios Tested

1. **Public documents** (f-public/*) - Everyone can read
2. **User-scoped** (f-user/named-grant.txt) - Only specific user
3. **Group-scoped** (f-group/group-only.txt) - Only group members
4. **Organisation link** (f-orglink/org-wide.txt) - Everyone in tenant
5. **No ACL readable** (i-noacl) - ACL read fails, tests fallback behavior

### Test Scenarios Enabled

- **Full batch sync** - All 8 documents indexed from root walk
- **Delta sync** - Change feed reports incremental updates
- **Deletion** - obsolete-note.txt removed in delta change #1
- **MIME filtering** - quarterly-report.pdf excluded when `EXCLUDE_MIME_TYPES=application/pdf`
- **Path scoping** - Selecting f-orglink only indexes org-wide.txt
- **Nested folders** - Deep nesting (f-nested/f-level-two/deep-file.txt)
- **ACL mapping** - Each permission type (public, user, group, org link)
- **Browse API** - Tree navigation with inScope/traversable annotations

---

## Setting Up a Real SharePoint Site

To test the connector against a real Microsoft 365 tenant, create a SharePoint document library
that mirrors the mock fixture structure.

### Prerequisites

- Microsoft 365 tenant with SharePoint Online
- Admin access to create a site and document library
- Entra ID app registration (see below)
- PowerShell with SharePoint PnP module OR Graph API access

### Site Structure

Create a site collection (e.g., `https://yourtenantname.sharepoint.com/sites/content-lake-demo`)
with a document library named "Shared Documents" containing:

```
Shared Documents/
├── Public/
│   ├── quarterly-review.txt
│   ├── incident-log.txt
│   └── quarterly-report.pdf
├── UserScoped/
│   └── named-grant.txt
├── GroupScoped/
│   └── group-only.txt
├── OrgLink/
│   └── org-wide.txt
└── Nested/
    └── LevelTwo/
        └── deep-file.txt
```

### Document Content

Each text file should contain a unique search phrase for verification:

- **quarterly-review.txt**: "This is the quarterly review for Q3 2026. Sentinel: pangolin-ledger-quarterly"
- **incident-log.txt**: "Security incident log for September. Sentinel: pangolin-ledger-incident"
- **named-grant.txt**: "Confidential user document. Sentinel: pangolin-ledger-user"
- **group-only.txt**: "Shared with project team. Sentinel: pangolin-ledger-group"
- **org-wide.txt**: "Organisation-wide announcement. Sentinel: pangolin-ledger-orgwide"
- **deep-file.txt**: "Nested folder test document. Sentinel: pangolin-ledger-nested"

The **quarterly-report.pdf** should be a real PDF containing "pangolin-ledger-pdf-report" for extraction testing.

### Permission Setup

Configure sharing permissions to match the test scenarios:

1. **Public folder** - Share with "Anyone with the link" (or everyone in tenant)
2. **UserScoped folder** - Share with a specific test user (e.g., testuser@yourtenant.com)
3. **GroupScoped folder** - Share with a specific Entra ID group
4. **OrgLink folder** - Share with an organisation link (everyone in tenant)
5. **Nested folder** - Inherit permissions from root (public)

### PowerShell Setup Script

```powershell
# Connect to SharePoint
Connect-PnPOnline -Url "https://yourtenant.sharepoint.com/sites/content-lake-demo" -Interactive

# Create folders
Add-PnPFolder -Name "Public" -Folder "Shared Documents"
Add-PnPFolder -Name "UserScoped" -Folder "Shared Documents"
Add-PnPFolder -Name "GroupScoped" -Folder "Shared Documents"
Add-PnPFolder -Name "OrgLink" -Folder "Shared Documents"
Add-PnPFolder -Name "Nested" -Folder "Shared Documents"
Add-PnPFolder -Name "LevelTwo" -Folder "Shared Documents/Nested"

# Upload sample files
Add-PnPFile -Path "quarterly-review.txt" -Folder "Shared Documents/Public"
Add-PnPFile -Path "incident-log.txt" -Folder "Shared Documents/Public"
Add-PnPFile -Path "quarterly-report.pdf" -Folder "Shared Documents/Public"
Add-PnPFile -Path "named-grant.txt" -Folder "Shared Documents/UserScoped"
Add-PnPFile -Path "group-only.txt" -Folder "Shared Documents/GroupScoped"
Add-PnPFile -Path "org-wide.txt" -Folder "Shared Documents/OrgLink"
Add-PnPFile -Path "deep-file.txt" -Folder "Shared Documents/Nested/LevelTwo"

# Set permissions (examples - adjust for your tenant)
Set-PnPFolderPermission -List "Shared Documents" -Identity "Public" -User "Everyone" -AddRole "Read"
Set-PnPFolderPermission -List "Shared Documents" -Identity "UserScoped" -User "testuser@yourtenant.com" -AddRole "Read" -ClearExisting
Set-PnPFolderPermission -List "Shared Documents" -Identity "GroupScoped" -Group "Project Team" -AddRole "Read" -ClearExisting
```

---

## Connector Configuration

### Entra ID App Registration

The connector requires an Entra ID app registration with appropriate permissions.

#### Application (Client) Permissions (App-Only Auth)

For unattended crawling across the tenant:

- **Sites.Read.All** - Read all site collections
- **Sites.FullControl.All** - Required for hierarchical permissions mode (optional)
- **GroupMember.Read.All** - Resolve Entra ID group membership (optional)

#### Delegated Permissions (Device Code Auth)

For testing under a specific user account:

- **Sites.Read.All** - Read sites the user can access
- **offline_access** - Get refresh tokens for background sync

### Configuration Examples

#### Against Mock (Static Token)

```bash
SHAREPOINT_AUTH_MODE=static-token
SHAREPOINT_ACCESS_TOKEN=mock-token-any-value
SHAREPOINT_CLIENT_ID=mock
SHAREPOINT_GRAPH_BASE_URL=http://mock-graph:8099/v1.0
SHAREPOINT_DRIVE_IDS=b!mock-drive-id
SHAREPOINT_RESOURCE_UNITS_PER_MINUTE=0
```

#### Against Real Tenant (App-Only)

```bash
SHAREPOINT_AUTH_MODE=client-credentials
SHAREPOINT_TENANT_ID=your-tenant-id-guid
SHAREPOINT_CLIENT_ID=your-app-registration-guid
SHAREPOINT_CLIENT_SECRET=your-client-secret
SHAREPOINT_SITE_URL=https://yourtenant.sharepoint.com/sites/content-lake-demo
SHAREPOINT_PERMISSIONS_MODE=per-item
```

#### Against Real Tenant (Device Code)

```bash
SHAREPOINT_AUTH_MODE=device-code
SHAREPOINT_TENANT_ID=your-tenant-id-guid
SHAREPOINT_CLIENT_ID=your-app-registration-guid
SHAREPOINT_TOKEN_CACHE_PATH=/var/lib/content-lake/token-cache.json
SHAREPOINT_SCOPES=Sites.Read.All,offline_access
SHAREPOINT_SITE_URL=https://yourtenant.sharepoint.com/sites/content-lake-demo

# First run: authenticate interactively
docker exec -it plugin-batch-ingester \
  java -cp /deployments/sharepoint-connector-*.jar \
  org.hyland.contentlake.connector.sharepoint.SharePointDeviceLogin
```

### Environment Variables

See `content-lake-app/plugins/sharepoint-connector/README.md` for the complete list of settings.

---

## Running Tests

### End-to-End Suite Against Mock

```bash
cd content-lake-app-deployment

# Ensure connector jar is built
cd ../content-lake-app
mvn -f plugins/sharepoint-connector/pom.xml package -DskipTests
cd ../content-lake-app-deployment

# Copy jar to connectors directory
mkdir -p connectors
cp ../content-lake-app/plugins/sharepoint-connector/target/sharepoint-connector-*.jar connectors/

# Run test suite
CONNECTOR_SYNC_USERNAME=admin CONNECTOR_SYNC_PASSWORD=admin \
RAG_AUTH=admin:admin ./test/test-sharepoint.sh
```

Expected output: **39 tests passing, 0 failing**

### Manual Verification Against Real Tenant

```bash
# Start plugin-batch-ingester with real tenant config
CONNECTOR_SYNC_USERNAME=admin CONNECTOR_SYNC_PASSWORD=admin \
CONNECTOR_SOURCE_TYPE=sharepoint \
SHAREPOINT_AUTH_MODE=client-credentials \
SHAREPOINT_TENANT_ID=your-tenant-id \
SHAREPOINT_CLIENT_ID=your-app-id \
SHAREPOINT_CLIENT_SECRET=your-secret \
SHAREPOINT_SITE_URL=https://yourtenant.sharepoint.com/sites/content-lake-demo \
  docker compose --profile alfresco --profile connector up -d

# Trigger sync
curl -u admin:admin -X POST http://localhost:9096/api/sync/configured

# Monitor job status
curl -u admin:admin http://localhost:9096/api/status | jq '.state, .nodesIndexed'

# Search for indexed documents
curl -u admin:admin -X POST http://localhost/api/rag/search/semantic \
  -H 'Content-Type: application/json' \
  -d '{"query": "pangolin-ledger-quarterly", "topK": 5}' | jq '.results[].sourceDocument.name'
```

---

## Troubleshooting

### Mock Graph Not Responding

```bash
# Check if mock-graph container is running
docker compose ps mock-graph

# Check mock logs
docker compose logs mock-graph --tail 50

# Verify mock is accessible
curl http://localhost:8099/mock-diagnostics/requests
```

### Connector Authentication Failures

```bash
# Check connector logs for auth errors
docker compose logs plugin-batch-ingester --tail 100

# Verify auth state
curl -u admin:admin http://localhost:9096/api/status | jq '.auth'

# For device-code: check token cache exists and is readable
docker exec plugin-batch-ingester ls -la /var/lib/content-lake/token-cache.json
```

### Documents Not Indexed

```bash
# Check sync job status
curl -u admin:admin http://localhost:9096/api/status | jq '.'

# Check for errors in ingester logs
docker compose logs plugin-batch-ingester | grep -i error

# Verify documents are discoverable
curl -u admin:admin "http://localhost:9096/api/browse/children?nodeId=b!mock-drive-id:root" | jq '.nodes[].name'
```

### Permission Mapping Issues

```bash
# Check ACL mapping in logs
docker compose logs plugin-batch-ingester | grep -i "permission\|acl"

# Verify group resolver is enabled if using groups
docker compose logs rag-service | grep -i "entra\|group"

# Test search with different users
curl -u testuser@yourtenant.com:password -X POST http://localhost/api/rag/search/semantic \
  -H 'Content-Type: application/json' \
  -d '{"query": "pangolin-ledger-user"}' | jq '.resultCount'
```

---

## References

- [SharePoint Connector Plugin README](../../content-lake-app/plugins/sharepoint-connector/README.md)
- [Mock Graph Server Source](../../content-lake-app/plugins/sharepoint-connector/src/test/java/org/hyland/contentlake/connector/sharepoint/mock/MockGraphServer.java)
- [Test Fixtures](../../content-lake-app/plugins/sharepoint-connector/src/test/resources/fixtures/)
- [E2E Test Suite](../test/test-sharepoint.sh)
- [Microsoft Graph API Documentation](https://learn.microsoft.com/en-us/graph/api/resources/driveitem)
