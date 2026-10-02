#!/bin/bash
# shared/personal-data-check.sh
# Block identity columns on operational tables. A repo may allow them by
# listing personal-store tables in config/personal_data.yml. The users table
# stays exempt so sign-in email is not treated as a personal-store column.

if [ -z "${RED+x}" ]; then
    if [ -t 1 ]; then
        RED='\033[0;31m'
        GREEN='\033[0;32m'
        YELLOW='\033[1;33m'
        NC='\033[0m'
    else
        RED=''
        GREEN=''
        YELLOW=''
        NC=''
    fi
fi

IDENTITY_COLUMNS='birth_number|rodne_cislo|phone_alt|phone|national_id'
COLUMN_TYPES='string|text|integer|bigint|decimal|float|numeric|boolean|date|datetime|time|binary|json|jsonb|uuid'

load_personal_tables() {
    PERSONAL_TABLES="users"
    local config="config/personal_data.yml"
    if [ ! -f "$config" ]; then
        return 0
    fi

    local in_tables=0
    local line name
    while IFS= read -r line || [ -n "$line" ]; do
        case "$line" in
            tables:*) in_tables=1; continue ;;
            [A-Za-z]*) in_tables=0 ;;
        esac
        if [ "$in_tables" = 1 ]; then
            name=$(printf '%s\n' "$line" | sed -nE 's/^[[:space:]]*-[[:space:]]*"?([A-Za-z0-9_]+)"?[[:space:]]*$/\1/p')
            if [ -n "$name" ]; then
                PERSONAL_TABLES="$PERSONAL_TABLES $name"
            fi
        fi
    done < "$config"
}

table_allowed() {
    local table="$1"
    local allowed
    for allowed in $PERSONAL_TABLES; do
        if [ "$allowed" = "$table" ]; then
            return 0
        fi
    done
    return 1
}

report_identity_column() {
    local file="$1"
    local table="$2"
    local column="$3"
    echo "${RED}❌ Identity column ${table}.${column} in ${file}${NC}"
    echo "${YELLOW}Put identity columns on a table listed in config/personal_data.yml.${NC}"
    echo "${YELLOW}Without that file, these columns are blocked on every table except users.${NC}"
    PERSONAL_DATA_FAILED=1
}

line_has_identity_column() {
    printf '%s\n' "$1" | grep -Eq "[:'\"](${IDENTITY_COLUMNS})([^A-Za-z0-9_]|$)"
}

identity_column_on_line() {
    printf '%s\n' "$1" | grep -Eo "[:'\"](${IDENTITY_COLUMNS})" | grep -Eo "(${IDENTITY_COLUMNS})" | head -1
}

table_name_on_line() {
    printf '%s\n' "$1" | sed -nE 's/.*(create_table|change_table|add_column)[[:space:]]*\(?[[:space:]]*[:'\''"]([A-Za-z0-9_]+).*/\2/p'
}

check_schema_like_file() {
    local file="$1"
    local current_table=""
    local in_table=0
    local line table column

    while IFS= read -r line || [ -n "$line" ]; do
        case "$line" in
            \#*) continue ;;
        esac

        if printf '%s\n' "$line" | grep -Eq 'create_table|change_table'; then
            table=$(table_name_on_line "$line")
            if [ -n "$table" ]; then
                current_table="$table"
                in_table=1
            fi
        fi

        if printf '%s\n' "$line" | grep -Eq 'add_column' && line_has_identity_column "$line"; then
            table=$(table_name_on_line "$line")
            column=$(identity_column_on_line "$line")
            if [ -n "$column" ] && ! table_allowed "$table"; then
                report_identity_column "$file" "${table:-unknown}" "$column"
            fi
        fi

        if [ "$in_table" = 1 ] && printf '%s\n' "$line" | grep -Eq "t\\.(${COLUMN_TYPES})[[:space:]]+" && line_has_identity_column "$line"; then
            column=$(identity_column_on_line "$line")
            if [ -n "$column" ] && ! table_allowed "$current_table"; then
                report_identity_column "$file" "${current_table:-unknown}" "$column"
            fi
        fi

        if [ "$in_table" = 1 ] && printf '%s\n' "$line" | grep -Eq '^[[:space:]]*end[[:space:]]*$'; then
            in_table=0
            current_table=""
        fi
    done < "$file"
}

snake_case() {
    printf '%s' "$1" | sed -E 's/([a-z0-9])([A-Z])/\1_\2/g' | tr '[:upper:]' '[:lower:]'
}

model_table_name() {
    local file="$1"
    local table class base
    table=$(sed -nE 's/.*self\.table_name[[:space:]]*=[[:space:]]*["'\'']([A-Za-z0-9_]+)["'\''].*/\1/p' "$file" | head -1)
    if [ -n "$table" ]; then
        printf '%s' "$table"
        return 0
    fi

    class=$(sed -nE 's/^class ([A-Za-z0-9_]+)( <.*)?$/\1/p' "$file" | head -1)
    if [ -z "$class" ]; then
        return 0
    fi
    base=$(snake_case "$class")
    case "$base" in
        *s) printf '%s' "$base" ;;
        *) printf '%s' "${base}s" ;;
    esac
}

check_model_file() {
    local file="$1"
    local line column table
    table=$(model_table_name "$file")
    if table_allowed "$table"; then
        return 0
    fi

    while IFS= read -r line || [ -n "$line" ]; do
        case "$line" in
            \#*) continue ;;
        esac
        if line_has_identity_column "$line"; then
            column=$(identity_column_on_line "$line")
            if [ -n "$column" ]; then
                report_identity_column "$file" "${table:-unknown}" "$column"
                return 0
            fi
        fi
    done < "$file"
}

is_personal_data_target() {
    case "$1" in
        db/migrate/*.rb|db/*migrate*/*.rb|*schema.rb|app/models/*.rb|app/models/*/*.rb)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

check_personal_data_files() {
    local files="$1"
    PERSONAL_DATA_FAILED=0
    load_personal_tables

    local file
    for file in $files; do
        if [ ! -f "$file" ]; then
            continue
        fi
        if ! is_personal_data_target "$file"; then
            continue
        fi
        case "$file" in
            app/models/*.rb|app/models/*/*.rb)
                check_model_file "$file"
                ;;
            *)
                check_schema_like_file "$file"
                ;;
        esac
    done

    if [ "$PERSONAL_DATA_FAILED" = 1 ]; then
        echo "${RED}🚨 Personal data check failed.${NC}"
        return 1
    fi

    echo "${GREEN}✅ Personal data stays in the personal store${NC}"
    return 0
}

check_personal_data_staged() {
    local staged_files
    staged_files=$(git diff --cached --name-only)
    echo "${YELLOW}🔒 Checking personal-data columns in staged files...${NC}"
    check_personal_data_files "$staged_files"
}

check_personal_data_commits() {
    local commits="$1"
    local files=""
    local commit changed
    for commit in $commits; do
        if [ "$commit" != "0000000000000000000000000000000000000000" ]; then
            changed=$(git diff-tree --no-commit-id --name-only -r "$commit")
            files="$files $changed"
        fi
    done
    echo "${YELLOW}🔒 Checking personal-data columns in commits...${NC}"
    check_personal_data_files "$files"
}
