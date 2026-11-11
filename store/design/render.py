"""Renders the App Store screenshots (iPhone 6.9", 1320x2868) for Ratify Music.

Each slide is an HTML page: a headline on a solid black background over a real
app screen (captured from the app on the iPhone 17 Pro Max simulator) in a
phone frame. Headless Chrome renders it at exactly 1320x2868.

    python3 store/design/render.py
Outputs: store/screenshots-6.9/01-....png
"""
import subprocess
from pathlib import Path

HERE = Path(__file__).resolve().parent
OUT = HERE.parent / "screenshots-6.9"
CHROME = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"

# (output name, screen, kicker, headline with <em> for the red words, subline)
SLIDES = [
    ("01-make-it-official", "s1.png", "THE SOCIAL MUSIC RANKING GAME",
     "Rank. Debate.<br><em>Make it official.</em>",
     "Settle the G.O.A.T. debate with your friends."),
    ("02-rank-your-top-5", "s2.png", "YOUR PICKS",
     "Rank your<br><em>Top 5.</em>",
     "Songs, albums and artists, or add your own."),
    ("03-crowd-decides", "s3.png", "THE COMMUNITY",
     "The crowd<br><em>decides.</em>",
     "Every vote shapes the official rankings."),
    ("04-pick-a-category", "s4.png", "CATEGORIES",
     "Pick a category.<br><em>Start the debate.</em>",
     "From '90s albums to the most iconic voices."),
    ("05-play-live", "s5.png", "LIVE &amp; APPLE MUSIC",
     "Play live.<br><em>Hear every pick.</em>",
     "Full songs with your Apple Music subscription."),
    ("06-try-free", "s6.png", "SOLO MODE",
     "Try it<br><em>for free.</em>",
     "Rank solo and see how you stack up."),
]

PAGE = """<!doctype html>
<html><head><meta charset="utf-8">
<style>
  :root {{ --bg: #080808; --red: #E3242B; --ink: #FFFFFF; --muted: #A1A1A6; }}
  * {{ margin: 0; padding: 0; box-sizing: border-box; }}
  html, body {{ width: 1320px; height: 2868px; background: var(--bg); overflow: hidden; }}
  body {{ font-family: -apple-system, "SF Pro Display", "Helvetica Neue", sans-serif; color: var(--ink);
         display: flex; flex-direction: column; align-items: center; }}
  .top {{ padding-top: 150px; text-align: center; width: 100%; }}
  .logo {{ width: 120px; height: 120px; display: block; margin: 0 auto 40px; }}
  .kicker {{ font-size: 34px; font-weight: 700; letter-spacing: 6px; color: var(--red); margin-bottom: 26px; }}
  h1 {{ font-size: 112px; line-height: 1.08; font-weight: 800; letter-spacing: 0.5px; }}
  h1 em {{ font-style: normal; color: var(--red); }}
  .sub {{ margin-top: 34px; font-size: 44px; line-height: 1.35; font-weight: 500; color: var(--muted); }}
  .phone {{ margin-top: 90px; width: 1000px; padding: 16px; border-radius: 120px;
           background: #1C1C1E; box-shadow: 0 0 0 3px #2C2C2E, 0 40px 120px rgba(0,0,0,.6); position: relative; }}
  .phone img.screen {{ display: block; width: 100%; border-radius: 104px; }}
  .island {{ position: absolute; top: 46px; left: 50%; width: 250px; height: 72px; margin-left: -125px;
            background: #000; border-radius: 40px; }}
</style></head>
<body>
  <div class="top">
    <img class="logo" src="logo.png" alt="">
    <div class="kicker">{kicker}</div>
    <h1>{headline}</h1>
    <div class="sub">{sub}</div>
  </div>
  <div class="phone"><img class="screen" src="{screen}" alt=""><div class="island"></div></div>
</body></html>
"""


def main() -> None:
    OUT.mkdir(exist_ok=True)
    for name, screen, kicker, headline, sub in SLIDES:
        html = HERE / f"_{name}.html"
        html.write_text(PAGE.format(screen=screen, kicker=kicker, headline=headline, sub=sub))
        png = OUT / f"{name}.png"
        subprocess.run([
            CHROME, "--headless=new", "--disable-gpu", "--hide-scrollbars",
            "--force-device-scale-factor=1", "--window-size=1320,2868",
            f"--screenshot={png}", html.as_uri(),
        ], check=True, capture_output=True)
        html.unlink()
        print("rendered", png.name)


if __name__ == "__main__":
    main()
