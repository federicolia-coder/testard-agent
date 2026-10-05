<p>
  <a href="https://platform.testardstudios.it">
    <picture>
      <source media="(prefers-color-scheme: dark)" srcset="assets/testard-wordmark-on-dark.svg">
      <img src="assets/testard-wordmark.svg" alt="testard." width="220">
    </picture>
  </a>
</p>

# testard-agent

A small, readable script that reports a Linux or Windows server's health to [Testard](https://platform.testardstudios.it), so servers at any provider (a VPS, a cloud VM, a machine in your office) show up next to your AWS, Google Cloud, Hetzner, DigitalOcean, Supabase and Cloudflare resources.

## Install

In Testard, open **Cloud Providers → Connect provider → Any server**, give the server a name, and copy the command it shows you. It looks like this:

```sh
curl -fsSL https://raw.githubusercontent.com/federicolia-coder/testard-agent/main/install.sh \
  | sudo sh -s -- --key tsk_... --url https://platform.testardstudios.it
```

The server appears in Testard within a minute.

Requirements: Linux, `curl`, and either systemd or cron. Tested with `dash` and `bash`.

### Windows

Pick **Windows** in the same dialog. In PowerShell opened with **Run as administrator**, paste the command it shows you:

```powershell
[Net.ServicePointManager]::SecurityProtocol = 'Tls12'; & ([scriptblock]::Create((irm https://raw.githubusercontent.com/federicolia-coder/testard-agent/main/install.ps1))) -Key tsk_... -Url https://platform.testardstudios.it
```

Requirements: Windows 10 or Windows Server 2016 and later, with the built-in Windows PowerShell 5.1. Nothing else to install.

## What it sends

Once a minute, one HTTPS request with:

| Field | Source |
| --- | --- |
| hostname, OS, kernel, architecture | `/proc/sys/kernel/hostname`, `/etc/os-release`, `uname` |
| CPU count, memory and root disk size | `getconf`, `/proc/meminfo`, `df /` |
| CPU, memory and disk usage (%) | `/proc/stat` (1-second sample), `/proc/meminfo`, `df /` |
| network throughput | `/proc/net/dev`, all interfaces except loopback |
| uptime, load average, private IP | `/proc/uptime`, `/proc/loadavg`, `ip route` |

On Windows the same figures come from `Win32_OperatingSystem`, `Win32_Processor` (load percentage), `Win32_LogicalDisk` (the system drive) and .NET's network interface statistics. Windows has no load average, so none is sent.

No file contents, process lists, environment variables, users or logs. Read [`testard-agent`](testard-agent) (Linux, about 125 lines) or [`testard-agent.ps1`](testard-agent.ps1) (Windows).

## What it never does

It never receives or runs commands. The key only allows submitting reports for this one server, so a leaked key can't be used to control the machine. To see exactly what would be sent:

```sh
testard-agent collect                                            # Linux
& "$env:ProgramFiles\TestardAgent\testard-agent.ps1" collect     # Windows
```

## How it runs

- Installed to `/usr/local/bin/testard-agent`, running as a dedicated `testard-agent` system user (no shell, no home). It doesn't need root.
- The key is stored in `/etc/testard-agent/auth-header` (mode 0600, readable by that user only) and passed to `curl` as a header file, so it never appears in the process list.
- A systemd timer (`testard-agent.timer`, hardened with `ProtectSystem=strict` and `NoNewPrivileges`) or, without systemd, `/etc/cron.d/testard-agent` runs it every minute.

```sh
testard-agent status              # configuration and last result
sudo testard-agent uninstall      # removes the agent, timer, user and files
```

On Windows:

- Installed to `C:\Program Files\TestardAgent\testard-agent.ps1`, which only administrators can change. A scheduled task, **Testard agent**, runs it every minute as the built-in `LOCAL SERVICE` account, which has no admin rights.
- The address and key are in `C:\ProgramData\TestardAgent`, readable only by `LOCAL SERVICE`, `SYSTEM` and administrators. The key is sent as a request header, never on a command line.

```powershell
& "$env:ProgramFiles\TestardAgent\testard-agent.ps1" status      # configuration and last result
& "$env:ProgramFiles\TestardAgent\testard-agent.ps1" uninstall   # elevated: removes the task and files
```

If a key is lost or leaked, create a new one in Testard (connection menu → **New agent key**) and run the install command again. The old key stops working immediately.

## License

Apache 2.0
