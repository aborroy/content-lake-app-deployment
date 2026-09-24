#!/usr/bin/env bash
# create-sharepoint-demo-files.sh - Generate sample files for SharePoint demo site
#
# Creates the fixture files needed to populate a SharePoint site that matches
# the mock Graph service structure used by test-sharepoint.sh.
#
# Usage:
#   ./fixtures/create-sharepoint-demo-files.sh [output-directory]
#
# The generated files can be uploaded to SharePoint manually or via PowerShell.

set -euo pipefail

OUTPUT_DIR="${1:-.sharepoint-demo-files}"

echo "Creating SharePoint demo fixture files in $OUTPUT_DIR"

# Create directory structure
mkdir -p "$OUTPUT_DIR"/{Public,UserScoped,GroupScoped,OrgLink,Nested/LevelTwo}

# Create text files with sentinel phrases for testing
cat > "$OUTPUT_DIR/Public/quarterly-review.txt" << 'EOF'
Q3 2026 Quarterly Review

This document contains the quarterly business review for Q3 2026.

Key highlights:
- Revenue increased 15% year-over-year
- Customer satisfaction scores improved
- New product launches on track

Sentinel phrase for testing: pangolin-ledger-quarterly
EOF

cat > "$OUTPUT_DIR/Public/incident-log.txt" << 'EOF'
Security Incident Log - September 2026

This log tracks security incidents reported during September.

Incidents:
- Sept 5: Phishing attempt detected and blocked
- Sept 12: Unusual login activity investigated
- Sept 20: Firewall rule updated after audit

Sentinel phrase for testing: pangolin-ledger-incident
EOF

cat > "$OUTPUT_DIR/Public/quarterly-report.pdf.txt" << 'EOF'
PLACEHOLDER FOR PDF

This is a placeholder text file. Replace this with an actual PDF file named:
quarterly-report.pdf

The PDF should contain the text "pangolin-ledger-pdf-report" to enable
text extraction testing.

You can create a simple PDF with:
- Microsoft Word: type the text and save as PDF
- LibreOffice Writer: type the text and export as PDF
- Online tools: Use any text-to-PDF converter

Content suggestion:
"Quarterly Financial Report Q3 2026

This report contains financial results for the third quarter.
Sentinel phrase: pangolin-ledger-pdf-report"
EOF

cat > "$OUTPUT_DIR/UserScoped/named-grant.txt" << 'EOF'
Confidential User Document

This document is shared with a specific user only and tests user-scoped
permissions in the SharePoint connector.

When setting up the SharePoint site, share this folder with a single
test user (e.g., testuser@yourtenant.com) and break permission inheritance.

Sentinel phrase for testing: pangolin-ledger-user
EOF

cat > "$OUTPUT_DIR/GroupScoped/group-only.txt" << 'EOF'
Project Team Document

This document is shared with a specific Entra ID group only and tests
group-scoped permissions in the SharePoint connector.

When setting up the SharePoint site, share this folder with an Entra ID
group (e.g., "Content Lake Testers") and break permission inheritance.

Sentinel phrase for testing: pangolin-ledger-group
EOF

cat > "$OUTPUT_DIR/OrgLink/org-wide.txt" << 'EOF'
Organisation-Wide Announcement

This document is shared via an organisation link, making it accessible to
everyone in the tenant (but not external users).

When setting up the SharePoint site, create an organisation sharing link
for this folder or use "People in your organization" sharing.

Sentinel phrase for testing: pangolin-ledger-orgwide
EOF

cat > "$OUTPUT_DIR/Nested/LevelTwo/deep-file.txt" << 'EOF'
Deeply Nested Document

This document tests that the connector correctly handles nested folder
structures and maintains path information through multiple levels.

The folder structure is: /Nested/LevelTwo/deep-file.txt

Sentinel phrase for testing: pangolin-ledger-nested
EOF

# Create a README with upload instructions
cat > "$OUTPUT_DIR/README.md" << 'EOF'
# SharePoint Demo Site Fixture Files

These files are generated to populate a SharePoint document library that matches
the structure used by the SharePoint connector's end-to-end test suite.

## Folder Structure

Upload these files to a SharePoint document library maintaining this structure:

```
Shared Documents/
├── Public/
│   ├── quarterly-review.txt
│   ├── incident-log.txt
│   └── quarterly-report.pdf        (CREATE THIS - see .txt placeholder)
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

## Permission Setup Required

After uploading, configure sharing permissions:

1. **Public folder** - Share with "Anyone with the link" or everyone in tenant
2. **UserScoped folder** - Share with ONE specific user, break inheritance
3. **GroupScoped folder** - Share with ONE Entra ID group, break inheritance
4. **OrgLink folder** - Create organisation link (everyone in tenant)
5. **Nested folder** - Inherit permissions from root (or make public)

## Upload via PowerShell

```powershell
# Connect to your SharePoint site
Connect-PnPOnline -Url "https://yourtenant.sharepoint.com/sites/your-site" -Interactive

# Upload all files maintaining structure
Add-PnPFile -Path "Public/quarterly-review.txt" -Folder "Shared Documents/Public"
Add-PnPFile -Path "Public/incident-log.txt" -Folder "Shared Documents/Public"
Add-PnPFile -Path "Public/quarterly-report.pdf" -Folder "Shared Documents/Public"
Add-PnPFile -Path "UserScoped/named-grant.txt" -Folder "Shared Documents/UserScoped"
Add-PnPFile -Path "GroupScoped/group-only.txt" -Folder "Shared Documents/GroupScoped"
Add-PnPFile -Path "OrgLink/org-wide.txt" -Folder "Shared Documents/OrgLink"
Add-PnPFile -Path "Nested/LevelTwo/deep-file.txt" -Folder "Shared Documents/Nested/LevelTwo"
```

## Verification

After setup, test with the SharePoint connector:

```bash
# Configure connector to point at your site
SHAREPOINT_SITE_URL=https://yourtenant.sharepoint.com/sites/your-site

# Trigger sync
curl -u admin:admin -X POST http://localhost:9096/api/sync/configured

# Search for each sentinel phrase to verify indexing
curl -u admin:admin -X POST http://localhost/api/rag/search/semantic \
  -H 'Content-Type: application/json' \
  -d '{"query": "pangolin-ledger-quarterly"}' | jq '.resultCount'

# Should return 1 result for each unique sentinel phrase:
# - pangolin-ledger-quarterly
# - pangolin-ledger-incident
# - pangolin-ledger-pdf-report (if PDF was created correctly)
# - pangolin-ledger-user
# - pangolin-ledger-group
# - pangolin-ledger-orgwide
# - pangolin-ledger-nested
```

## See Also

- [SharePoint Deployment Documentation](../docs/deployment-sharepoint.md)
- [SharePoint Connector README](../../content-lake-app/plugins/sharepoint-connector/README.md)
- [E2E Test Suite](../test/test-sharepoint.sh)
EOF

# Create a simple PDF generation helper
cat > "$OUTPUT_DIR/create-pdf.sh" << 'EOF'
#!/bin/bash
# Helper to create the quarterly-report.pdf if you have pandoc installed

if ! command -v pandoc &> /dev/null; then
    echo "pandoc is not installed. Install it or create the PDF manually."
    echo "On macOS: brew install pandoc"
    echo "On Ubuntu: apt-get install pandoc texlive-latex-base"
    exit 1
fi

cat > /tmp/quarterly-report.md << 'MDEOF'
# Quarterly Financial Report

## Q3 2026 Results

This report contains the financial results for the third quarter of 2026.

### Revenue
- Total revenue: $10.2M
- Growth: 15% YoY

### Expenses
- Operating expenses: $6.8M
- Net income: $3.4M

**Sentinel phrase for testing:** pangolin-ledger-pdf-report

This document is used by the SharePoint connector test suite to verify
that PDF text extraction is working correctly.
MDEOF

pandoc /tmp/quarterly-report.md -o Public/quarterly-report.pdf
echo "Created Public/quarterly-report.pdf"
rm /tmp/quarterly-report.md
EOF

chmod +x "$OUTPUT_DIR/create-pdf.sh"

echo ""
echo "Fixture files created successfully in $OUTPUT_DIR"
echo ""
echo "Next steps:"
echo "  1. Create quarterly-report.pdf (run $OUTPUT_DIR/create-pdf.sh or create manually)"
echo "  2. Upload files to SharePoint (see $OUTPUT_DIR/README.md for instructions)"
echo "  3. Configure folder permissions as documented"
echo "  4. Test with the SharePoint connector"
echo ""
echo "For detailed setup instructions, see:"
echo "  content-lake-app-deployment/docs/deployment-sharepoint.md"
