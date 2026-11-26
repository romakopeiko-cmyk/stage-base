"""Check supplied Google Drive links anonymously, without storing response data."""
from concurrent.futures import ThreadPoolExecutor
from urllib.error import HTTPError, URLError
from urllib.parse import urlsplit
from urllib.request import HTTPRedirectHandler, Request, build_opener
import http.client


class DriveRedirects(HTTPRedirectHandler):
    def redirect_request(self, request, fp, code, message, headers, new_url):
        parsed = urlsplit(new_url)
        if parsed.scheme != "https" or parsed.hostname not in (
            "drive.google.com", "docs.google.com", "accounts.google.com", "drive.usercontent.google.com"
        ):
            raise URLError("Непідтримуване переспрямування")
        return super().redirect_request(request, fp, code, message, headers, new_url)


def photo_status(url):
    parsed = urlsplit(url)
    if parsed.scheme != "https" or parsed.hostname != "drive.google.com" or parsed.username or parsed.password:
        return "Поза підтримуваним доменом"
    try:
        request = Request(url, headers={"User-Agent": "Mozilla/5.0"})
        with build_opener(DriveRedirects()).open(request, timeout=8) as response:
            if urlsplit(response.url).hostname == "accounts.google.com":
                return "Потрібен вхід або доступ"
            mime = response.headers.get_content_type()
            if mime.startswith("image/"):
                return "Зображення доступне"
            html = response.read(160000).decode("utf-8", "replace").lower()
            if any(marker in html for marker in ("you need access", "request access", "немає доступу", "потрібен доступ")):
                return "Потрібен вхід або доступ"
            if 'drive-viewer' in html or 'og:title' in html or 'viewerng' in html:
                return "Сторінка Drive відкривається; файл не звірено"
            return "Відповідь Drive не підтверджує доступ"
    except HTTPError as error:
        if error.code in (401, 403):
            return "Потрібен вхід або доступ"
        if error.code in (404, 410):
            return "Не знайдено без входу"
        return f"Доступ не підтверджено (HTTP {error.code})"
    except (URLError, TimeoutError, OSError, http.client.HTTPException):
        return "Доступ не підтверджено (мережа)"


def check_links(links):
    with ThreadPoolExecutor(max_workers=10) as pool:
        return dict(zip(links, pool.map(photo_status, links)))
