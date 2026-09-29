import os

def parse_issue_body(body):
    """
    Parses GitHub Issue Form markdown into extracted field values.
    Handles sections matching '### <Label>' headers.
    """
    sections = []
    current_label = None
    current_lines = []

    for line in body.splitlines():
        if line.startswith("### "):
            if current_label:
                sections.append((current_label, " ".join(current_lines).strip()))
            current_label = line.replace("### ", "").strip()
            current_lines = []
        elif current_label and line.strip():
            if line.strip() != "_No response_":
                current_lines.append(line.strip())

    if current_label:
        sections.append((current_label, " ".join(current_lines).strip()))

    data = {}
    working_status_occurrences = 0

    for label, val in sections:
        # Escape pipe characters so they don't break the Markdown table
        clean_val = val.replace("|", "\\|")
        
        # Handle duplicate "Working Status" headers if present
        if label == "Working Status":
            working_status_occurrences += 1
            if working_status_occurrences == 1:
                data["scanner_status"] = clean_val
            else:
                data["button_status"] = clean_val
        elif "Hardware Button" in label or "button" in label.lower():
            data["button_status"] = clean_val
        elif "Model" in label:
            data["scanner_model"] = clean_val
        elif "Notes" in label:
            data["notes"] = clean_val

    return data

def main():
    issue_body = os.environ.get("ISSUE_BODY", "")
    parsed = parse_issue_body(issue_body)

    model = parsed.get("scanner_model", "Unknown Model")
    status = parsed.get("scanner_status", "Unknown")
    button = parsed.get("button_status", "N/A")
    notes = parsed.get("notes", "-")

    if not notes:
        notes = "-"

    # Construct the Markdown table row
    new_row = f"| {model} | {status} | {button} | {notes} |\n"

    readme_path = "README.md"
    with open(readme_path, "r", encoding="utf-8") as f:
        content = f.read()

    target_marker = "<!-- SCANNERS_END -->"
    if target_marker in content:
        updated_content = content.replace(target_marker, f"{new_row}{target_marker}")
        with open(readme_path, "w", encoding="utf-8") as f:
            f.write(updated_content)
        print(f"Successfully added {model} to {readme_path}")
    else:
        print("Error: Marker <!-- SCANNERS_END --> not found in README.md")

if __name__ == "__main__":
    main()
