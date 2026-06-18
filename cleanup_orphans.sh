#!/bin/bash
# Detect and clean orphan attachments in a self-hosted Outline wiki.
#
# Three categories of orphans are found:
#   C1. Attachment row exists, file on disk exists, but the linked document
#       is gone from the `documents` table (hard-deleted). File is still
#       served via /api/attachments.redirect?id=<id>.
#   C2. Attachment row exists, file on disk exists, but no document or
#       revision references the attachment anywhere. Likely uploaded but
#       never inserted into a document (or removed during editing).
#   C3. Attachment row exists, but file on disk is missing. Document may or
#       may not reference it — either way the URL returns 404. Safe to
#       delete the DB row alone.
#
# Two-phase workflow:
#   ./cleanup_orphans.sh scan     # detect, write .orphans_report.tsv, print summary
#   ./cleanup_orphans.sh show     # print the saved report with URLs to verify
#   ./cleanup_orphans.sh clean    # ask per-category, then delete DB rows + files
#   ./cleanup_orphans.sh help
#
# Before running `clean`, edit .orphans_report.tsv and change the ACTION
# column from "delete" to "keep" for any item you want to preserve.
#
# NOTE on the report file separator:
#   The report uses `|` (pipe) as the field separator, NOT a literal tab.
#   Reason: bash's `read` with `IFS=$'\t'` collapses consecutive tabs into
#   one separator — i.e. an empty field in the middle of a TSV row is
#   silently dropped and every variable after it shifts left by one. C3
#   rows have an empty `disk_path` field (file already missing), so they
#   look like `...|no|<tab><tab>|doc|delete` and the `action` variable
#   ends up empty, causing the row to be skipped with no warning. `|` is
#   a non-whitespace IFS character, so empty fields are preserved.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")" && pwd)"
# File name kept as .tsv for historical reasons; the content is pipe-separated.
REPORT_FILE="$REPO_ROOT/.orphans_report.tsv"
UPLOADS_DIR="$REPO_ROOT/data/outline/uploads"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

log() { printf '\033[1;34m[orphan-cleanup]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[orphan-cleanup]\033[0m %s\n' "$*" >&2; }
err() { printf '\033[1;31m[orphan-cleanup]\033[0m %s\n' "$*" >&2; }

# Pick a working docker compose invocation (v1 `docker-compose` or v2
# `docker compose`). Mirror the logic in scripts/main.sh.
docker_compose_cmd() {
    if command -v docker-compose >/dev/null 2>&1; then
        echo "docker-compose"
    else
        echo "docker compose"
    fi
}

# Discover the postgres container name. Prefer the compose service name
# `wk-postgres` (resolves via docker compose), fall back to a name match.
pg_container() {
    local dc; dc="$(docker_compose_cmd)"
    local name
    name="$($dc -f "$REPO_ROOT/docker-compose.yml" ps -q wk-postgres 2>/dev/null || true)"
    if [ -n "$name" ]; then
        # ps -q returns the short id; resolve to a container name.
        docker inspect --format '{{.Name}}' "$name" 2>/dev/null | sed 's|^/||'
        return
    fi
    docker ps --format '{{.Names}}' --filter 'name=wk-postgres' | head -1
}

# Run a SQL query against the outline postgres database. Output is
# pipe-separated (one row per line, columns separated by `|`) so the caller
# can `read` into variables with `IFS='|'`. We use `|` (not tab) because
# bash's `read` collapses consecutive IFS whitespace, which would drop
# empty middle fields (e.g. attachments with a NULL `documentId`).
pg_query() {
    local sql="$1"
    local container; container="$(pg_container)"
    if [ -z "$container" ]; then
        err "postgres container not found. Is the stack running?"
        exit 1
    fi
    docker exec "$container" psql -U user -d outline -tA -F '|' -c "$sql"
}
read_url() {
    if [ -n "${OUTLINE_URL:-}" ]; then
        echo "$OUTLINE_URL"
        return
    fi
    if [ -f "$REPO_ROOT/env.outline" ]; then
        grep -E '^URL=' "$REPO_ROOT/env.outline" | head -1 | cut -d= -f2-
    fi
}

# ---------------------------------------------------------------------------
# Phase 1: scan
# ---------------------------------------------------------------------------

do_scan() {
    : > "$REPORT_FILE"

    log "Scanning attachments in database and uploads/ on disk ..."
    log "  uploads dir: $UPLOADS_DIR"
    log "  report file: $REPORT_FILE"

    if [ ! -d "$UPLOADS_DIR" ]; then
        err "uploads directory not found at $UPLOADS_DIR"
        exit 1
    fi

    local url; url="$(read_url)"
    if [ -z "$url" ]; then
        warn "could not detect OUTLINE_URL; URLs in the report will be empty"
    fi

    # Pull every document text blob and revision text blob to /tmp so we
    # can grep attachment references without round-tripping psql for every
    # ID. The blobs are small (a few MB) so this is fine.
    local tmp; tmp="$(mktemp -d)"
    # NOTE: use double quotes so $tmp is expanded at trap-set time (the
    # local var is gone by the time the trap fires on EXIT).
    trap "rm -rf '$tmp'" EXIT

    pg_query "SELECT text FROM documents WHERE text IS NOT NULL" > "$tmp/docs.tsv"
    pg_query "SELECT text FROM revisions WHERE text IS NOT NULL" > "$tmp/revs.tsv"

    # Combined referenced attachment IDs (doc + revision).
    grep -ohE 'attachments\.redirect\?id=[a-f0-9-]{36}' \
        "$tmp/docs.tsv" "$tmp/revs.tsv" \
        | sed 's|.*id=||' | sort -u > "$tmp/referenced.txt"

    local total_db=0 total_disk=0 referenced=0
    local c1=0 c2=0 c3=0

    # Stream every attachment row from the DB and classify it.
    # `|` matches pg_query's -F '|' output; an empty `documentId` (NULL →
    # empty string) would be a second `|` in a row, which would collapse
    # under `IFS=$'\t'`.
    while IFS='|' read -r att_id doc_id att_size; do
        total_db=$((total_db + 1))

        # Compute the disk path for this attachment. Layout is:
        #   uploads/<userId>/<attachmentId>/<filename>
        # We don't know userId a priori, so resolve via `find`.
        local disk_dir
        disk_dir="$(find "$UPLOADS_DIR" -mindepth 2 -maxdepth 2 -type d -name "$att_id" 2>/dev/null | head -1 || true)"
        local disk_exists="no"
        local disk_size=0
        local disk_path=""
        if [ -n "$disk_dir" ]; then
            disk_exists="yes"
            disk_size=$(du -sb "$disk_dir" 2>/dev/null | cut -f1)
            disk_path="$disk_dir"
            total_disk=$((total_disk + 1))
        fi

        # Is the attachment referenced anywhere?
        local is_referenced="no"
        if grep -qx "$att_id" "$tmp/referenced.txt" 2>/dev/null; then
            is_referenced="yes"
            referenced=$((referenced + 1))
        fi

        # Categorise. Default action: "delete" for every category, the user
        # can edit the TSV afterwards to flip any item to "keep".
        local category doc_title_or_gone action
        if [ "$is_referenced" = "yes" ]; then
            # Referenced attachments are healthy. Skip them.
            continue
        fi

        if [ -n "$doc_id" ]; then
            # Look up the parent document title (or note that it's gone).
            doc_title_or_gone="$(pg_query "SELECT title FROM documents WHERE id = '$doc_id'" || true)"
            if [ -z "$doc_title_or_gone" ]; then
                category="C1_deleted_doc"
                doc_title_or_gone="GONE($doc_id)"
            else
                category="C2_unreferenced"
            fi
        else
            # No documentId at all — treat like C2 but flag the row.
            category="C2_unreferenced"
            doc_title_or_gone="(no documentId)"
        fi

        # Override: file missing on disk → C3 regardless of category.
        if [ "$disk_exists" = "no" ]; then
            # C3 wins because the file is already gone; the DB row is just
            # the residue.
            category="C3_missing_file"
        fi

        action="delete"
        printf '%s|%s|%s|%s|%s|%s|%s|%s\n' \
            "$category" "$att_id" "$att_size" "$disk_size" "$disk_exists" \
            "$disk_path" "$doc_title_or_gone" "$action" \
            >> "$REPORT_FILE"

        case "$category" in
            C1_*) c1=$((c1 + 1)) ;;
            C2_*) c2=$((c2 + 1)) ;;
            C3_*) c3=$((c3 + 1)) ;;
        esac
    done < <(pg_query "SELECT id, COALESCE(\"documentId\"::text, ''), size FROM attachments ORDER BY \"createdAt\"" | sed 's/|$//')

    local referenced_skip=$((total_db - referenced))
    log ""
    log "Scan complete."
    log "  attachments in DB:        $total_db"
    log "  unique IDs on disk:       $total_disk"
    log "  referenced (kept):        $referenced"
    log "  skipped (referenced):     $referenced_skip"
    log "  C1 deleted-doc orphans:   $c1"
    log "  C2 unreferenced orphans:  $c2"
    log "  C3 missing-file ghosts:   $c3"

    if [ "$((c1 + c2 + c3))" -eq 0 ]; then
        log "Nothing to do."
        rm -f "$REPORT_FILE"
        return
    fi

    log ""
    log "Wrote report to $REPORT_FILE"
    log "Next: review URLs (next 20 lines), then run ./cleanup_orphans.sh show"
    log "      to see everything, or ./cleanup_orphans.sh clean to delete."
    log ""
    if [ -n "$url" ]; then
        log "Verify any item in your browser by visiting:"
        log "  ${url}/api/attachments.redirect?id=<attachment-id>"
        log ""
    fi

    # Print the first 20 lines so the user can see the format.
    head -20 "$REPORT_FILE" | awk -F'|' -v url="$url" 'BEGIN{
        printf "%-18s %-36s %10s %10s %-4s %-30s %s\n",
            "CATEGORY","ATTACHMENT_ID","DB_SIZE","DISK_SIZE","DISK","DOC","URL"
    }{
        u = (url == "" ? "" : url "/api/attachments.redirect?id=" $2)
        printf "%-18s %-36s %10s %10s %-4s %-30s %s\n",
            $1,$2,$3,$4,$5,substr($7,1,30),u
    }'

    if [ "$(wc -l < "$REPORT_FILE")" -gt 20 ]; then
        log ""
        log "(... $(($(wc -l < "$REPORT_FILE") - 20)) more lines — run ./cleanup_orphans.sh show to see all)"
    fi
}

# ---------------------------------------------------------------------------
# show
# ---------------------------------------------------------------------------

do_show() {
    if [ ! -f "$REPORT_FILE" ]; then
        err "no report at $REPORT_FILE — run ./cleanup_orphans.sh scan first"
        exit 1
    fi

    local url; url="$(read_url)"
    log "Report: $REPORT_FILE  ($(wc -l < "$REPORT_FILE") rows)"
    log "URL base: ${url:-<unset>}"
    log ""

    awk -F'|' -v url="$url" 'BEGIN{
        printf "%-18s %-36s %10s %10s %-4s %-30s %-6s %s\n",
            "CATEGORY","ATTACHMENT_ID","DB_SIZE","DISK_SIZE","DISK","DOC","ACTION","URL"
    }{
        u = (url == "" ? "" : url "/api/attachments.redirect?id=" $2)
        printf "%-18s %-36s %10s %10s %-4s %-30s %-6s %s\n",
            $1,$2,$3,$4,$5,substr($7,1,30),$8,u
    }' "$REPORT_FILE"

    log ""
    log "Edit $REPORT_FILE and change the ACTION column from 'delete' to 'keep'"
    log "for any item you want to preserve, then run ./cleanup_orphans.sh clean."
}

# ---------------------------------------------------------------------------
# Phase 2: clean
# ---------------------------------------------------------------------------

do_clean() {
    if [ ! -f "$REPORT_FILE" ]; then
        err "no report at $REPORT_FILE — run ./cleanup_orphans.sh scan first"
        exit 1
    fi

    local url; url="$(read_url)"

    # Build per-category counts of items flagged "delete".
    local c1 c2 c3
    c1=$(awk -F'|' '$1=="C1_deleted_doc" && $8=="delete"' "$REPORT_FILE" | wc -l | tr -d ' ')
    c2=$(awk -F'|' '$1=="C2_unreferenced" && $8=="delete"' "$REPORT_FILE" | wc -l | tr -d ' ')
    c3=$(awk -F'|' '$1=="C3_missing_file" && $8=="delete"' "$REPORT_FILE" | wc -l | tr -d ' ')

    log "Items flagged for deletion:"
    log "  C1 (deleted-doc):  $c1"
    log "  C2 (unreferenced): $c2"
    log "  C3 (missing file): $c3"
    log ""

    if [ "$((c1 + c2 + c3))" -eq 0 ]; then
        log "Nothing flagged for deletion (every item is ACTION=keep)."
        return
    fi

    if [ -t 0 ] && [ -z "${YES:-}" ]; then
        log "About to delete: DB rows + on-disk files for C1/C2; DB rows only for C3."
        log "This is IRREVERSIBLE. Type 'yes' to proceed: "
        read -r confirm
        if [ "$confirm" != "yes" ]; then
            log "Aborted."
            return
        fi
    else
        log "Non-interactive mode (or YES=1) — proceeding without prompt."
    fi

    local db_deleted=0 disk_deleted=0 disk_bytes=0
    local line_num=0
    # Use `|` (not tab) for IFS: tab is a whitespace IFS char, and bash's
    # `read` collapses runs of whitespace, which would drop the empty
    # `disk_path` field on C3 rows and shift `action` left into nothing.
    while IFS='|' read -r category att_id db_size disk_size disk_exists disk_path doc_title action; do
        line_num=$((line_num + 1))
        [ "$action" = "delete" ] || continue

        # 1. Always remove the DB row.
        local container; container="$(pg_container)"
        if docker exec "$container" psql -U user -d outline -c "DELETE FROM attachments WHERE id = '$att_id'" >/dev/null; then
            db_deleted=$((db_deleted + 1))
        else
            warn "  [skip] failed to DELETE attachment $att_id from DB"
            continue
        fi

        # 2. For C1/C2 the file should also be on disk — remove its dir.
        if [ "$category" = "C1_deleted_doc" ] || [ "$category" = "C2_unreferenced" ]; then
            if [ -n "$disk_path" ] && [ -d "$disk_path" ]; then
                rm -rf "$disk_path"
                disk_deleted=$((disk_deleted + 1))
                disk_bytes=$((disk_bytes + disk_size))
            fi
        fi
    done < "$REPORT_FILE"

    log ""
    log "Done."
    log "  DB rows deleted:    $db_deleted"
    log "  Files deleted:      $disk_deleted"
    log "  Disk space freed:   $disk_bytes bytes ($(awk -v b="$disk_bytes" 'BEGIN{printf "%.1f", b/1024/1024}') MiB)"

    log ""
    log "Removing stale report. Run ./cleanup_orphans.sh scan again to verify."
    rm -f "$REPORT_FILE"
}

# ---------------------------------------------------------------------------
# help
# ---------------------------------------------------------------------------

do_help() {
    cat <<EOF
cleanup_orphans.sh — find and remove orphan Outline attachments

Usage:
    ./cleanup_orphans.sh scan    Detect orphans, write .orphans_report.tsv
    ./cleanup_orphans.sh show    Print the saved report with verify-URLs
    ./cleanup_orphans.sh clean   Delete rows flagged ACTION=delete in the report
    ./cleanup_orphans.sh help    This help

Workflow:
    1. scan    → reads DB + disk, classifies every attachment, writes TSV
    2. show    → visit the URLs printed here to confirm the images are
                 truly orphaned; edit the TSV to flip ACTION=delete to
                 ACTION=keep for anything you want to preserve
    3. clean   → re-reads the TSV, deletes DB rows (+ files for C1/C2)

Environment:
    OUTLINE_URL   Override the public URL used when printing verify links
                  (defaults to URL from env.outline)
    YES=1         Skip the interactive confirmation prompt on clean
EOF
}

# ---------------------------------------------------------------------------
# main
# ---------------------------------------------------------------------------

cmd="${1:-scan}"
case "$cmd" in
    scan)  do_scan ;;
    show)  do_show ;;
    clean) do_clean ;;
    help|-h|--help) do_help ;;
    *) err "unknown command: $cmd"; do_help; exit 1 ;;
esac