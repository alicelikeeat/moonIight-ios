"""Probe public provider schemas without keys or downloading media files."""
import concurrent.futures
import json
import urllib.parse
import urllib.request


def get(base, **params):
    url = base + ("?" + urllib.parse.urlencode(params) if params else "")
    request = urllib.request.Request(url, headers={"User-Agent": "Moonlight-iOS/2.0 source-check"})
    with urllib.request.urlopen(request, timeout=12) as response:
        return json.load(response)


def check(name):
    if name == "NASA":
        rows = get("https://images-api.nasa.gov/search", q="space", media_type="video", page_size=1)["collection"]["items"]
        item = rows[0]["data"][0]
        assets = get("https://images-api.nasa.gov/asset/" + urllib.parse.quote(item["nasa_id"], safe=""))["collection"]["items"]
        assert any(row["href"].lower().endswith(".mp4") for row in assets), "No MP4 asset"
    elif name == "Archive":
        rows = get("https://archive.org/advancedsearch.php", **{"q": 'mediatype:movies AND format:"MPEG4" AND space', "fl[]": "identifier,title,creator", "rows": 1, "output": "json"})["response"]["docs"]
        assert "identifier" in rows[0], "Missing identifier"
    elif name == "Dailymotion":
        rows = get("https://api.dailymotion.com/videos", sort="trending", limit=1, fields="id,title,thumbnail_720_url,owner.screenname")["list"]
        assert "id" in rows[0], "Missing video ID"
    elif name == "PeerTube":
        rows = get("https://sepiasearch.org/api/v1/search/videos", search="nature", count=1, start=0, nsfw="false")["data"]
        assert rows[0]["account"]["host"] and rows[0]["uuid"], "Missing instance / video ID"
    elif name == "Commons":
        result = get("https://commons.wikimedia.org/w/api.php", action="query", format="json", generator="search", gsrnamespace=6, gsrlimit=1, gsrsearch="nature filetype:video", prop="imageinfo", iiprop="url|mime", iiurlwidth=640)
        rows = list(result["query"]["pages"].values())
        assert rows[0]["imageinfo"][0]["url"], "Missing video URL"
    else:
        raise ValueError(name)
    return len(rows)


def probe(name):
    try:
        return name, "OK", str(check(name)) + " result; schema matched"
    except Exception as error:
        return name, "Unavailable", str(error).replace("|", "/").replace("\n", " ")[:180]


if __name__ == "__main__":
    lines = ["| Source | Result | Details |", "|---|---|---|"]
    with concurrent.futures.ThreadPoolExecutor(max_workers=5) as pool:
        for name, status, detail in pool.map(probe, ["NASA", "Archive", "Dailymotion", "PeerTube", "Commons"]):
            lines.append(f"| {name} | {status} | {detail} |")
    report = "\n".join(lines) + "\n"
    print(report)
    with open("build/source-check.md", "w", encoding="utf-8") as output:
        output.write(report)
