# proxmox-scripts

Proxmox-hjælpescripts i samme stil som [community-scripts.org](https://community-scripts.org/): én linje på Proxmox-værten opretter og installerer en LXC-container.

## pixi-hub

Opretter en unprivileged **Debian 13**-container til [pixi-hub](https://github.com/subjektivdk/pixi-hub) (privat). Den beriger Obsidian daily notes, og vaultet synkes med [Obsidian Headless Sync](https://obsidian.md/help/sync/headless) i stedet for en kørende Obsidian-desktop.

Kør som root i Proxmox-shellen:

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/subjektivdk/proxmox-scripts/main/ct/pixi-hub.sh)"
```

**Standard:** næste ledige CT-ID, hostname `pixi-hub`, 2 kerner, 1 GB RAM, 8 GB disk på `local-lvm`, DHCP på `vmbr0`, `Europe/Copenhagen`, `onboot=1`. Vælg **Avanceret** for fast IP, SSH-nøgle osv. Du kan også sætte værdierne på forhånd, fx `var_net=192.168.1.50/24 var_gateway=192.168.1.1 bash -c "$(curl …)"`.

### Hvad scriptet gør
1. Henter `debian-13-standard`-templaten, hvis den mangler, og opretter og starter containeren (`nesting=1`).
2. Installerer Node.js 24 LTS, `obsidian-headless` (`ob`), `uv`, `rclone`, `rsync` (til hubbens backup), `age`, Claude Code og brugeren `pixi` med linger. Login-shells læser hubbens `env`, og `/usr/local/bin/pixi-hub` gør det samme for kommandoer over ssh, så `ssh pixi@pixi-hub pixi-hub …` har de samme hemmeligheder som tjenesten (og `nano` som editor i TUI'en). Det laver også en **deploy key** og `obsidian-sync.service`.
3. Spørger, om opsætningen skal gøres færdig nu (`pixi-hub-lxc setup`):
   - viser deploy key'en, som du tilføjer som **read-only** på GitHub, og kloner og installerer så pixi-hub (`uv tool install …[jev]`)
   - `ob login` (e-mail, password, 2FA), vælg vault, og E2EE-password, hvis vaultet er end-to-end-krypteret
   - starter sync i **pull-only**, kun noter (ingen vedhæftninger, ingen `.obsidian`-config)
   - **Hetzner Storage Box**: brugernavn og password. Det gemmes som rclone-remoten `hetzner-sbox` (passwordet bliver obscured via stdin og havner ikke i historikken), og forbindelsen testes med det samme
   - **Claude Code** (valgfrit): `claude setup-token` med dit abonnement; tokenen gemmes som `CLAUDE_CODE_OAUTH_TOKEN` i `env` og testes med Haiku. Bruges kun af readiness-challengers, der spørger Claude
   - **hemmeligheder** til `~/.config/pixi-hub/env` (chmod 600): `TYPESAFE_API_KEY` (Jev), `ELOVERBLIK_REFRESH_TOKEN` og `EASEE_USERNAME`/`EASEE_PASSWORD` (electricity). Tom = behold den gamle værdi.

**pixi-hub's scheduler startes ikke.** Det sker først med `pixi-hub-lxc go-live`, så hubben aldrig kører to steder på én gang.

### I containeren: `pixi-hub-lxc`
| Kommando | Gør |
|---|---|
| `pixi-hub-lxc status` | Hvad er installeret, sat op, migreret og kørende |
| `pixi-hub-lxc config` | **Menu** med ✔/✖ for Hetzner, hemmeligheder, GitHub og Obsidian. Vælg det, der mangler |
| `pixi-hub-lxc claude` | Installerer Claude Code og logger ind med en abonnements-token |
| `pixi-hub-lxc hub-update` | Kun pixi-hub: `git pull` fra main, installerer og genstarter hubben. Virker også som brugeren `pixi` over ssh |
| `pixi-hub-lxc setup` | Det hele i rækkefølge: GitHub, Obsidian, Hetzner, hemmeligheder (kan køres igen) |
| `pixi-hub-lxc hetzner` / `secrets` / `github` / `obsidian` | Kun den ene del |
| `pixi-hub-lxc go-live` | Tjekker at config, database og vault er på plads, skifter sync til bidirectional og starter pixi-hub, pebble- og backup-timeren |
| `pixi-hub-lxc pause` | Stopper pixi-hub igen (sync kører videre), fx for at rulle tilbage |
| `update` / `pixi-hub-lxc update` | Debian, obsidian-headless, disse scripts og pixi-hub. `update` virker som i community-scripts' containere. Som `pixi` (over ssh) opdaterer den kun pixi-hub |

`status` viser også, om Zabbix kan nås, om `tasks_command` findes, og om `claude` findes (kun hvis en challenger bruger den). Fra Proxmox-værten: `pct exec <id> -- pixi-hub-lxc status`. Kører du `ct/pixi-hub.sh` inde i containeren, opdaterer den.

### Udvikling og opdatering
Alt hentes fra **GitHub**: pixi-hub med `git pull` (read-only deploy key) og disse scripts fra `raw.githubusercontent.com`. Hetzner Storage Box har kun data (urdata, filer til telefonen, backup), aldrig kode.

1. Udvikl og test på pixi som nu: `uv run pytest`, og prøv mod en kopi af data med `--dry-run`. **Start aldrig scheduleren på pixi**, når containeren kører.
2. Push til `main`.
3. Rul ud: `ssh pixi@pixi-hub pixi-hub-lxc hub-update`. Kommandoen viser de nye commits, installerer, kopierer systemd-units og genstarter hubben. Den stopper med en fejl, hvis hubben ikke kommer op igen.
4. Rul tilbage: `git revert` på pixi, push, og kør `hub-update` igen.

Config og data bor i containeren, så du ændrer dem dér: `ssh pixi@pixi-hub pixi-hub config set …` (laver stadig git-commits i `~/.config/pixi-hub`). Debian og obsidian-headless opdateres med `update` en gang imellem. Der er ingen automatisk udrulning: en fejl pushet om aftenen skal ikke ramme 05:00-briefen.

### Baren og TUI'en på pixi
Omarchy-pluginet i pixi-hub (`deploy/omarchy/`) virker også, når hubben kører her ([pixi-hub#16](https://github.com/subjektivdk/pixi-hub/issues/16)):
- Sæt pluginets **pixi-hub command** til `~/Projects/pixi-hub/deploy/omarchy/pixi-hub-remote` og **Obsidian-vault** til vaultets navn på pixi. `pixi-hub-remote` kører `pixi-hub` her over ssh (`PIXI_HUB_HOST`, standard `pixi@pixi-hub`) med én delt forbindelse.
- Klik åbner TUI'en over `ssh -t`; højreklik åbner statusnoten i pixi's egen Obsidian.
- pixi skal kunne logge ind som `pixi` med nøgle (sæt den med **Avanceret → SSH-nøgle**, når containeren oprettes).

### Det gør scriptet ikke
Hubbens **data** flyttes ikke: config, `env`, database, `imports/`, `last-backup` og age-nøglen til urdata. Det er en del af selve skiftet, se [pixi-hub#18](https://github.com/subjektivdk/pixi-hub/issues/18). `status` viser, hvad der mangler.

### Sikkerhed
- Repoet indeholder ingen hemmeligheder. Deploy key'en laves i containeren og forlader den aldrig.
- Containeren lytter kun på SSH. pixi-hub henter selv sine data.
- Obsidian-tokenen ligger i `~/.config/obsidian-headless/auth_token` hos brugeren `pixi`.

## Test
GitHub Actions kører shellcheck og hele `install/pixi-hub-install.sh` i en Debian 13-container med systemd ved hvert push.

MIT-licens.
