import requests
import json

BASE_URL = "https://lyrics-api.boidu.dev"
USER_AGENT = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36"

headers = {
    "User-Agent": USER_AGENT,
    "Accept": "application/json"
}

# List of potential endpoints to probe
endpoints_to_test = [
    "/",
    "/getLyrics",
    "/search",
    "/info",
    "/status",
    "/v1/lyrics",
]

# Common query parameters for testing
test_params = {
    "a": "Rick Astley",
    "s": "Never Gonna Give You Up",
    "artist": "Rick Astley",
    "song": "Never Gonna Give You Up",
    "q": "Rick Astley"
}

def probe_api():
    documentation = {}

    print(f"--- Probing {BASE_URL} ---")

    for path in endpoints_to_test:
        url = f"{BASE_URL}{path}"
        print(f"\nTesting: {url}")
        
        try:
            # We test GET by default; you can expand this to POST/OPTIONS
            response = requests.get(url, headers=headers, params=test_params, timeout=5)
            
            # Record basic metadata
            documentation[path] = {
                "status_code": response.status_code,
                "content_type": response.headers.get("Content-Type", "Unknown"),
                "is_json": False,
                "sample_data": None
            }

            # Filter for JSON only as requested
            if "application/json" in response.headers.get("Content-Type", "").lower():
                documentation[path]["is_json"] = True
                try:
                    data = response.json()
                    documentation[path]["sample_data"] = data
                    print(f"[SUCCESS] JSON found at {path}")
                except json.JSONDecodeError:
                    print(f"[ERROR] Declared JSON but failed to parse at {path}")
            else:
                print(f"[SKIP] Non-JSON content at {path} ({response.headers.get('Content-Type')})")

        except Exception as e:
            print(f"[FAILURE] Could not connect to {path}: {e}")

    # Save findings to a local file
    with open("api_discovery_report.json", "w") as f:
        json.dump(documentation, f, indent=4)
    
    print(f"\n--- Probe Complete. Results saved to api_discovery_report.json ---")

if __name__ == "__main__":
    probe_api()

