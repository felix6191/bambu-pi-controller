# Bambu Pi Image — für Kund:innen (Bambu Leipzig)

So kommt der Pi ohne Technikwissen ans Laufen. Alles andere macht die App.

## 0 · Fertiges Image laden (empfohlen)

1. Auf **github.com/felix6191/bambu-pi-controller → Releases** gehen.
2. **`bambu-controller.img.xz`** herunterladen (wird bei jedem Release automatisch gebaut).
3. Weiter bei Schritt 1.

*Kein Release da? Einmalig: GitHub → Actions → „Pi-Image bauen“ → Run workflow — danach liegt das Image als Download bereit.*

## 1 · SD-Karte flashen (5 Min, einmalig)

1. **Raspberry Pi Imager** laden (raspberrypi.com/software) und öffnen.
2. **Betriebssystem wählen → „Eigenes Image"** → `bambu-controller.img` vom USB-Stick wählen.
3. **SD-Karte wählen → Schreiben.** Fertig.
4. Tipp: Wer WLAN statt Kabel nutzt, klickt vorher aufs Zahnrad und trägt Heim-WLAN ein.

## 2 · Anschließen (2 Kabel)

1. SD-Karte in den Pi, **Strom** anstecken.
2. **Internet**: LAN-Kabel zum Router (oder WLAN wie oben).
3. 3–5 Minuten warten (der Pi richtet sich selbst ein — grüne LED blinkt).

## 3 · App laden & verbinden

1. App öffnen → **„Los geht's"** → der Pi erscheint von allein → **„Verbinden"** antippen.
2. Kein Tippen von Nummern nötig — das regeln Pi und App unter sich.

## Wenn der Pi nicht erscheint

- Gleiches WLAN am Handy wie am Pi? (Kein Gast-WLAN.)
- Pi-Strom prüfen, 2 Minuten warten, in der App **„Erneut suchen"**.
- Notfall: WLAN `Bambu-Setup-XXXX` am Handy wählen (Passwort `bambu-setup`), dann in der App verbinden.
