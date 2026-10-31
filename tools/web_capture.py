#!/usr/bin/env python3
"""Drive the exported web build in Chromium: desktop + emulated phone.

Captures the title screen and gameplay so we can verify the HTML5 build and
the touch interface outside of the native Wayland run.
"""
import asyncio
import os
import sys

from playwright.async_api import async_playwright

URL = "http://127.0.0.1:8080/index.html"
OUT = "/home/user/eight_pages/screenshots/web"


async def main() -> int:
    os.makedirs(OUT, exist_ok=True)
    logs = []
    async with async_playwright() as p:
        browser = await p.chromium.launch(
            executable_path="/usr/bin/chromium",
            args=[
                "--no-sandbox",
                "--use-gl=angle",
                "--use-angle=swiftshader",
                "--enable-unsafe-swiftshader",
                "--autoplay-policy=no-user-gesture-required",
            ],
        )

        async def open_game(context, name, click=True):
            page = await context.new_page()
            page.on("console", lambda m: logs.append(f"[{name}] {m.type}: {m.text}"))
            page.on("pageerror", lambda e: logs.append(f"[{name}] pageerror: {e}"))
            await page.goto(URL, wait_until="domcontentloaded")
            # wait for the canvas and for Godot to finish compiling
            await page.wait_for_selector("#canvas", timeout=60000)
            await page.wait_for_timeout(35000)
            await page.screenshot(path=f"{OUT}/{name}_title.png")
            if click:
                # click "BEGIN" (canvas position scaled)
                box = await page.locator("#canvas").bounding_box()
                await page.mouse.click(box["x"] + box["width"] * 0.5, box["y"] + box["height"] * 0.553)
                await page.wait_for_timeout(6000)
                await page.screenshot(path=f"{OUT}/{name}_start.png")
            return page

        # ---------------- desktop ----------------------------------------
        ctx_desktop = await browser.new_context(viewport={"width": 1280, "height": 720})
        page = await open_game(ctx_desktop, "desktop")
        await page.wait_for_timeout(2000)
        await page.screenshot(path=f"{OUT}/desktop_world.png")
        await ctx_desktop.close()

        # ---------------- phone (touch) -----------------------------------
        iphone = p.devices["iPhone 13"]
        ctx_phone = await browser.new_context(**iphone)
        page2 = await open_game(ctx_phone, "phone")
        await page2.wait_for_timeout(1500)
        await page2.screenshot(path=f"{OUT}/phone_world.png")
        # drag the virtual stick then swipe to look, mid-run
        w = iphone["viewport"]["width"]
        h = iphone["viewport"]["height"]
        await page2.touchscreen.tap(w * 0.16, h * 0.176)
        await page2.wait_for_timeout(2500)
        await page2.screenshot(path=f"{OUT}/phone_touch_ui.png")
        # simulated thumb on the stick + swipe to look
        await page2.touchscreen.tap(w * 0.5, h * 0.55)
        await page2.wait_for_timeout(1200)
        await page2.screenshot(path=f"{OUT}/phone_world2.png")
        await ctx_phone.close()
        await browser.close()

    with open(f"{OUT}/console.log", "w") as f:
        f.write("\n".join(logs[-120:]))
    print("\n".join(logs[-30:]))
    print("web capture done:", OUT)
    return 0


if __name__ == "__main__":
    sys.exit(asyncio.run(main()))
