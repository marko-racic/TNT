# TNT Changelog

## 2.5.0

- Adds IP Information to Diagnostics
- Accepts an IPv4 address or hostname
- Uses the current Public IP when input is left empty
- Displays country, region, city, ISP, ASN, timezone and approximate coordinates
- Uses ipwho.is over HTTPS without adding external dependencies

## 2.4.7

- Reduced the initial Terminal window from 143×50 to 90×32
- Added active-interface MAC address detection
- Displays MAC address directly below Primary interface
- Includes MAC address in copied network information

## 2.4.6

- Final simplified About screen
- Centers the TNT ASCII logo and project information
- Displays Troubleshooting Network Tool, 2.4.5, author, website, and macOS/Bash
- Removes the previous network summary and detailed metadata from About

## 2.4.5

- Redesigned the main dashboard Network Health and DNS Servers sections
- Displays Network Health in the left column and DNS Servers in the right column
- Uses the same responsive two-column layout as the rest of the dashboard
- Supports displaying up to four configured DNS servers

## 2.4.4

- Fixes the first TNT logo row appearing shifted
- Centers the complete logo using one fixed 27-column block
- Pads every logo row to exactly the same width
- Uses the shared logo renderer in Splash and About

## 2.4.3

- Replaced Unicode TNT artwork with a width-safe plain-ASCII logo
- Uses the same aligned logo in both the splash and About screens
- Prevents skew caused by ambiguous-width block and box-drawing characters
- Keeps existing branding, website, and author information unchanged

## 2.4.2

- Replaced the skewed About-screen TNT artwork
- Added a symmetrical, evenly spaced six-line ASCII logo
- Preserved the existing About layout and branding

## 2.4.1

- Added the TNT ASCII logo to the About screen
- Updated the website to `https://marko.racic.rs`
- Corrected the author name to Marko Racić
- Updated footer branding

## 2.4.0

- Finalizes the terminal Diagnostics screen
- Keeps the network header, menu, prompt, and result title fixed
- Restricts scrolling to the result pane beginning at row 28
- Reads all interactive diagnostic input directly from the active Terminal
- Adds TCP Port Test with `host:port` input and a five-second timeout
- Reports resolved IPv4, connection result, command output, and elapsed time

## 2.3.6

- Redesigned the main Actions menu into two balanced columns
- Left column: Refresh, Diagnostics, Network Configuration, Network Settings
- Right column: Copy Information, Toggle Refresh, About TNT, Quit
- Updated main-menu key mappings to match the new layout

## 2.3.5

- Fixes Diagnostics menu keys 1–6 and B not responding
- Repairs an accidental function replacement that put menu logic inside the target prompt
- Reads menu keys and text input directly from `/dev/tty`
- Initializes `DIAGNOSTIC_INPUT` for compatibility with `set -u`
- Fixes unconditional returns after diagnostic target entry
- Restores terminal input mode before every menu or prompt read

## 2.3.4

- Fixes unresponsive numeric choices in the Diagnostics menu
- Replaces Bash `read -n 1` with a dedicated macOS-safe single-key reader
- Explicitly restores terminal input mode after every key read
- Resets Terminal to sane mode before menu input and on application cleanup

## 2.3.3

- Rebuilds Diagnostics as a fixed-position Terminal layout
- Prevents the header and menu from disappearing after target entry
- Establishes the results scroll region before command output begins
- Uses absolute rows for header, menu, prompt, and output title
- Removes cursor-position queries and pre-freeze natural scrolling

## 2.3.2

- Fixes the Diagnostics screen disappearing after target entry
- Detects the actual cursor row before enabling the result scroll region
- Removes reliance on a fixed output row
- Preserves all content already displayed above the result area
- Explicitly restores the cursor after setting Terminal scroll margins

## 2.3.1

- Freezes the network header, Diagnostics menu, prompt, and output title
- Ping and Traceroute results scroll only in the lower output region
- DNS and Reverse DNS results use the same lower scrolling region
- Does not redraw the frozen area while commands are running
- Restores normal Terminal scrolling after every diagnostic and on exit

## 2.3.0

- Redesigned Diagnostics as one persistent screen
- Network header and Diagnostics menu remain visible while entering targets
- Ping and Traceroute output continue directly below the menu
- DNS Lookup and Reverse DNS results continue directly below the menu
- Removed diagnostic screen clearing and alternate scroll regions
- Added a consistent inline output panel for all diagnostic tools

## 2.2.4

- Ping, Traceroute, DNS Lookup, and Reverse DNS prompts now appear below the Diagnostics submenu
- The submenu remains visible while entering a host or IP
- TNT switches to the diagnostic output screen only after input is submitted

## 2.2.3

- Added one shared TNT header for every secondary screen
- Standardized Network Configuration and Diagnostics submenu headers
- Ping, Traceroute, DNS Lookup, and Reverse DNS now use the same header
- About and Self-Test also use the shared network context header
- Shared header shows network service, interface, IP, gateway, DNS, and VPN

## 2.2.2

- Redesigned Diagnostics submenu to match Network Configuration
- Added current service, interface, IP, gateway, DNS, and VPN summary
- Preserved single-key navigation

## 2.2.1

- Fixes corrupted Ping and Traceroute diagnostic layout
- Removes concurrent live header redraw while commands produce output
- Keeps the compact header frozen and stable
- Corrects the diagnostic header scroll-region row count
- Preserves Q and Esc interruption

## 2.2.0

- Added compact persistent diagnostic header
- Shows Interface, IP, Gateway, DNS, and VPN during diagnostics
- Added live status indicators
- Ping and Traceroute output scroll beneath a frozen header
- Header refreshes periodically while diagnostics run
- Restores the normal Terminal scroll region on exit

## 2.1.1

- Fixes Ping and Traceroute on macOS Bash 3.2
- Replaces unsupported fractional `read -t 0.2` timeout with integer timeout
- Q and Esc still stop running diagnostics

## 2.1.0

- Redesigned main Actions menu
- Added single-key Diagnostics submenu
- Added continuous Ping with resolved IPv4 display
- Added interruptible live Traceroute
- Added formatted DNS Lookup for A, AAAA, CNAME, MX, NS, and TXT
- Added Reverse DNS with forward-confirmation check
- Moved DNS flush and DHCP renewal into Diagnostics
- No export or resolver selector added

## 2.0.0

- Officially renamed the application to TNT
- Expanded name: Troubleshooting Network Tool
- Added branded splash screen
- Added marko.racic.rs to the About screen and footer
- Renamed app, Dock title, Terminal title, logs, and application-support folder
- Added TNT app icon
- Added initial source tree and repeatable build system
- Preserved the complete working Network Toolbox 1.2.8 feature set
