# Underground Nexus — Sovereign Kernel Layer

**Policy-guided automation that builds and governs your infrastructure.**

> **One-liner:**
> Nexus is a **sovereign systems layer** that uses **curated artifacts** and an **agentic kernel** to assemble, harden, and prove compliant infrastructure—on any hardware or cloud.

<p align="center">
  <img src="https://github.com/Underground-Ops/underground-nexus/blob/main/Graphics/SVG/cloud-underground-logo.svg" alt="Cloud Underground Logo" width="300px" height="300px">
  <img src="https://github.com/Underground-Ops/underground-nexus/blob/main/Graphics/SVG/new-nexus-logo.svg" alt="Underground Nexus Logo" width="300px" height="300px">
</p>

**Release Version 2.0.1 – RELEASE NAME: CodeHaven**

---

## Quick hero (site copy, optional)

**Underground Nexus: Sovereign Systems Layer**
Turn policies into running systems – build sovereign zones, automate controls, and generate audit evidence by default.
**CTA:** Explore the Gauntlet → | See the Architecture →

**Underground Nexus: Governance OS**
Artifact-driven, agent-operated infrastructure. Requirements in. Sovereign zones out. Evidence on.
**CTA:** Start in the Gauntlet → | Read the README →

> **What we’ve retired:**
> “Copy/paste data center” and “DevSecOps software factory” (still true internally) are no longer how buyers describe what Nexus does. We also avoid unexplained kernel/Kubernetes jargon on public pages.

---

## Table of Contents

* [Intro & Helpful Links](#intro--helpful-links)
* [Best Way to Install (Cerberus Manager)](#best-way-to-install-cerberus-manager)
* [Manual Install Step 1](#manual-install-step-1)
* [Manual Install Step 2 (Activation)](#manual-install-step-2-activation)
* [How to Use Underground Nexus (Once Deployed)](#how-to-use-underground-nexus-once-deployed)
* [Deploying Virtual Machines](#deploying-virtual-machines)
* [Architecture & Diagrams](#architecture--diagrams)
* [Super Root — Sovereign Kernel (new)](#super-root—sovereign-kernel-new)
* [Sovereign Kernel Layer: What It Means](#sovereign-kernel-layer-what-it-means)
* [Artifacts, Chaos Testing, and Golden Hosts](#artifacts-chaos-testing-and-golden-hosts)
* [Beginner Mental Model (Windows Analogy)](#beginner-mental-model-windows-analogy)
* [Learn More](#learn-more)
* [Helpful Videos](#helpful-videos)

---

## Intro & Helpful Links

The **Underground Nexus** is a **Sovereign Kernel Layer** – a governance-first systems layer that compiles policy and requirements into **sovereign zones** and emits **audit evidence by default**. It’s artifact-driven and agent-operated, so you can evolve infrastructure from a living reference without vendor lock-in.

* **Official repository:** [https://github.com/Underground-Ops/underground-nexus](https://github.com/Underground-Ops/underground-nexus)
* **Best way to learn (Cloud Jam Gauntlet):** [https://cloudunderground.dev/products/cloud-jam](https://cloudunderground.dev/products/cloud-jam)
* **Recommended installer & package manager (Cerberus0 Manager CLI):** [https://github.com/Underground-Ops/underground-nexus/tree/cerberus0](https://github.com/Underground-Ops/underground-nexus/tree/cerberus0)

<img src="https://github.com/Underground-Ops/underground-nexus/blob/cdcb0a3ee862c8c4f029fed6c45fe280786d4173/Graphics/SVG/nexus-software-factory.svg" alt="Underground Nexus Software Factory">

**Use cases you can start with**

* Build a minimum viable product
* Stand up pre-governed configurations for GRC automation
* Run a home lab for hands-on learning
* Use Nexus as a **golden host** template to craft virtual appliances

---

## Best Way to Install (Cerberus Manager)

**Recommended for most users:** the **Cerberus (cerberus0) Manager CLI** bundles the full pipeline and provides a smoother UX.

* Cerberus0 Manager: [https://github.com/Underground-Ops/underground-nexus/tree/cerberus0](https://github.com/Underground-Ops/underground-nexus/tree/cerberus0)

**Kickstart with Cerberus (typical flow)**

1. Install Cerberus0 Manager per repo instructions and use its shell to deploy virtual environments.
2. Use the **`DEV`** command to set up your development workspace and fetch core artifacts.
3. Use the **`SEC`** command to run a chaos test that builds a golden host appliance template if the test succeeds. (the **`SEC`** command deploys the Dockerfile image in this repository)
4. Continue in the **Cloud Jam Gauntlet** for structured learning.

> You can still use the **manual** Docker commands below. Commands, ports, credentials, and activation flow remain the same.

---

## Manual Install Step 1

> Assumes **Docker is already installed**. Open a command line and paste the appropriate `docker run` for your platform.

**Dockerhub *DEVELOPMENT* pull for *Docker Desktop or amd64* systems:**

```
docker run -itd --name=Underground-Nexus -h Underground-Nexus --privileged --init \
  -p 22:22 -p 80:80 -p 8080:8080 -p 443:443 -p 1000:1000 \
  -p 2375:2375 -p 2376:2376 -p 2377:2377 -p 9010:9010 -p 9050:9443 \
  -p 18080:8080 -p 18443:18443 \
  -v /dev:/dev -v underground-nexus-docker-socket:/var/run \
  -v underground-nexus-data:/var/lib/docker/volumes -v nexus-bucket:/nexus-bucket \
  natoascode/underground-nexus:amd64
```

**Dockerhub *SECURE* pull for *Docker Desktop or amd64* systems:**

```
docker run -itd --name=Underground-Nexus -h Underground-Nexus --privileged --init \
  -p 1000:1000 -p 9050:9443 \
  -v /dev:/dev -v underground-nexus-docker-socket:/var/run \
  -v underground-nexus-data:/var/lib/docker/volumes -v nexus-bucket:/nexus-bucket \
  natoascode/underground-nexus:amd64
```

**Dockerhub *DEVELOPMENT* pull for *arm64* systems (examples include Apple M1, Raspberry Pi, NVIDIA Jetson, etc.):**

```
docker run -itd --name=Underground-Nexus -h Underground-Nexus --privileged --init \
  -p 22:22 -p 80:80 -p 8080:8080 -p 443:443 -p 1000:1000 \
  -p 2375:2375 -p 2376:2376 -p 2377:2377 -p 9010:9010 -p 9050:9443 \
  -p 18080:8080 -p 18443:18443 \
  -v /dev:/dev -v underground-nexus-docker-socket:/var/run \
  -v underground-nexus-data:/var/lib/docker/volumes -v nexus-bucket:/nexus-bucket \
  natoascode/underground-nexus:arm64
```

**Dockerhub *SECURE* pull for *arm64* systems (examples include Apple M1, Raspberry Pi, NVIDIA Jetson, etc.):**

```
docker run -itd --name=Underground-Nexus -h Underground-Nexus --privileged --init \
  -p 1000:1000 -p 9050:9443 \
  -v /dev:/dev -v underground-nexus-docker-socket:/var/run \
  -v underground-nexus-data:/var/lib/docker/volumes -v nexus-bucket:/nexus-bucket \
  natoascode/underground-nexus:arm64
```

---

## Manual Install Step 2 (Activation)

> Run in the **same shell** used for docker run. Script builds and activates the stack. Expect **15–45 minutes** on average.

**Standard Activation (recommended):**

```
docker exec Underground-Nexus bash deploy-olympiad.sh
```

**Alternate Activation (inside container shell):**

```
bash deploy-olympiad.sh
```

**Lightweight Activation (for < 8GB RAM):**
Removes KuberNexus, underground-ops.me domain, and non-essential tools (Vault, SOC, Traefik, WordPress, GitLab, collaborator workbenches, k3d/Kubernetes).

```
bash olympiad-deploy-light.sh
```

**Portainer login ([https://localhost:9050](https://localhost:9050)):**

* Reset Portainer if locked out:
  `docker exec Underground-Nexus docker restart Olympiad0`
* After install completes, go to **[http://localhost:1000](http://localhost:1000)**, open **Firefox**, and use the **Git-BIOS Control Panel** to get started.

> **Minimum hardware:** Raspberry Pi 4 (4GB RAM+) or anything more powerful (amd64/arm supported).

---

## How to Use Underground Nexus (Once Deployed)

1. **Admin desktop**:
   Open the Nexus MATE admin desktop at **[http://localhost:1000](http://localhost:1000)**.

   * On ARM, install Visual Studio Code manually.
   * On amd64, you’ll see VS Code, GitHub Desktop, and GitKraken in the MATE desktop.
   * The webtop is a **load balancer**, not just a desktop.

2. **Secure port strategy**:
   Nexus is designed to operate primarily from **one open port**: **1000**.

   * Optional second secure port: **[https://localhost:9050](https://localhost:9050)** (Portainer).
   * Optional SOC desktop: **[http://localhost:2000](http://localhost:2000)**.
   * **Security note:** port **1000** is a portal to root access—treat accordingly.

3. **Kubernetes (KuberNexus)**:
   In Portainer, find **KuberNexus** for Kubernetes. Use the MATE terminal with `k3d` to create/modify clusters.

4. **Nexus apps**:
   Accessible via Firefox (or any browser) inside the MATE admin desktop.

5. **SSO / Developer flow**:
   GitHub works well for SSO. VS Code + GitHub Codespaces is a fast way to scale dev compute.

6. **Kali shell security**:
   Kali is locked behind Portainer by default. Configure SSH to allow access to the entire Nexus **through the Kali Athena0 node** as a gateway.

7. **Monitoring**:
   The **Athena0** (Kali) node feeds **Grafana** and **Loki** and includes **radare2** for deep analysis.

8. **Pi-hole mode**:
   Open DNS ports (**53**, **67**) to run Nexus as a powerful Pi-hole + SOC source. Integrate Pi-hole data with Grafana/Loki.

9. **Default internal URLs** (available **inside** the Nexus desktop browser):

   * Portainer: `https://10.20.0.1:9443`
   * Pi-hole: `http://inner-dns-control/admin/login.php` (change password in Portainer)
   * Grafana: `https://grafana.underground-ops.me/` and `http://10.20.0.1:3000/`

     * default `admin:notiaPoint1`
   * Wazuh: `https://wazuh.underground-ops.me:5601/` and `https://10.20.0.1:5601/`

     * default `admin:admin`
   * MinIO (Cyber Life Torpedo): `http://10.20.0.1:9010`

     * default `minioadmin:minioadmin`
   * Ubuntu MATE Admin Desktop: `http://10.20.0.1:1000`

     * default `abc:abc` (runs as root; don’t access this host from inside the MATE desktop)
   * Ubuntu KDE SOC Desktop: `http://10.20.0.1:2000`

     * default `abc:abc`
   * Vault: `http://10.20.0.1:8200`

     * default password `myroot` (do **not** expose externally)
   * VS Code (browser): `http://10.20.0.1:18443`
   * VM Engine (Hyperscaler): `http://10.20.0.1:18080`

10. **External development ports** (open intentionally––recommended defaults are **1000** and **9443**):

    * Portainer: **9050** → `https://localhost:9050`
    * Kali Athena0: **22** (enable SSH inside Kali first)
    * Pi-hole: **80**, **53** → `http://localhost`
    * MinIO: **9010** → `http://localhost:9010`
    * Admin Desktop: **1000** → `http://localhost:1000`
    * SOC Desktop: **2000** → `http://localhost:2000`
    * VS Code (browser): **18443** → `http://localhost:18443`

11. **Athena0 (Kali) for pentest & chaos**:

    * Tools: Terraform (`terraform`), Metasploit (`msfconsole`), `nmap`, Kali **Bleeding Edge** repo
    * Configure SSH (port **22**) behind a firewall for remote Nexus access
    * From host shells: `docker exec Athena0 <cmd>` (e.g., `docker exec Athena0 terraform -v`)
    * Use with Terraform + Metasploit for **Chaos Engineering** and delivery
    * Useful for **bug bounty** workflows

12. **Terraform pre-installed**:

    * Use from MATE terminal for general work
    * Use from **Athena0** for super-admin work that needs full `root`

13. **GitLab (amd64 standard activation)**:

    * The standard activation builds a self-hosted GitLab.
    * Other variants deploy GitLab Runners that you can pair to external GitLab.
    * The MATE webtop home page (Git-BIOS) includes “Getting Started with GitLab.”

> Learn GitLab + DevSecOps with Cloud Underground:
> [https://learn.gitlab.com/cloud-underground/](https://learn.gitlab.com/cloud-underground/)

---

## Deploying Virtual Machines

Nexus includes **Virtual Machine Manager** and **QEMU** for running VMs inside the stack.

* Screenshots:

  * <img src="https://github.com/Underground-Ops/underground-nexus/blob/cdcb0a3ee862c8c4f029fed6c45fe280786d4173/Using_Virtual_Machines__1.PNG" alt="VM steps 1-2">
  * <img src="https://github.com/Underground-Ops/underground-nexus/blob/cdcb0a3ee862c8c4f029fed6c45fe280786d4173/Using_Virtual_Machines__2.PNG" alt="VM steps 3-4">
  * <img src="https://github.com/Underground-Ops/underground-nexus/blob/cdcb0a3ee862c8c4f029fed6c45fe280786d4173/Using_Virtual_Machines__3.PNG" alt="VM steps 5">

---

## Architecture & Diagrams

* **Cloud-Native Server Architecture (PDF):**
  [https://github.com/Underground-Ops/underground-nexus/blob/main/Underground_Nexus_Architecture.pdf](https://github.com/Underground-Ops/underground-nexus/blob/main/Underground_Nexus_Architecture.pdf)

* **Quick Start Guide (pay special attention to Step 4; dockerhub users start at Step 3):**
  [https://github.com/Underground-Ops/underground-nexus/blob/main/Underground_Nexus_Quick_Guide.pdf](https://github.com/Underground-Ops/underground-nexus/blob/main/Underground_Nexus_Quick_Guide.pdf)

<img src="https://github.com/Underground-Ops/underground-nexus/blob/cdcb0a3ee862c8c4f029fed6c45fe280786d4173/Graphics/SVG/super-root-cluster.svg" alt="Underground Nexus Super Roots">

---

## Super Root — Sovereign Kernel (new)

This section replaces and modernizes the older "super root" content.

### What is a Super Root

A **Super Root** is the privileged sovereign-kernel control plane for an Underground Nexus deployment. It is the logical layer that:

* bootstraps and governs the platform from the lowest reliable control points
* owns platform policy and signed configuration artifacts
* exposes guarded APIs for agentic automation and human gates
* provides the root of trust you control – keys, attestations, and provenance

The Super Root is not a single binary. It is a configuration of kernel-level controls, hypervisor boundaries, curated artifacts, and agent interfaces that together form a secure substrate for sovereign zones.

### Super Root configuration — core components

A Super Root configuration typically includes:

* **KVM/QEMU** – hardware-assisted virtualization used to create strong VM isolation.
* **Network primitives** – hardware offload and NIC partitioning such as SR-IOV for deterministic I/O.
* **Kernel-level enforcement** – eBPF policies and host protections applied early in the packet path.
* **Policy-as-artifact** – policy, runbooks, and playbooks stored as versioned artifacts (Git) and governed by CI/CD runners.
* **Agent surface** – guarded APIs that agents use to observe, decide, and act with human approval gates.
* **Firmware & BIOS governance** – managed firmware updates and attestations using signed flows and fwupd/LVFS where supported.
* **Provenance tooling** – SLSA/in-toto-style attestations attached to builds, images, and changes.

### How a Super Root creates a sovereign zone

1. Anchor trust to keys you control. Sign configs, images, and firmware.
2. Enforce controls at the kernel and NIC path – restrict device DMA, packet handling, and virtual function mapping.
3. Use agentic automations to carry out policy-as-code – automatic actions require approval for high-risk changes.
4. Produce attestations and audit bundles for every artifact, run, and change. Continuous evidence reduces audit burden.

### Practical Super Root patterns (how we implement it in Nexus)

* Keep privileged operations narrow – prefer KVM-hosted services rather than privileged containers for critical functions when possible.
* When a privileged container is necessary for bootstrapping – constrain capabilities, use SELinux/AppArmor, limit cgroups and namespaces.
* Use SR-IOV or PCIe passthrough for predictable hardware I/O for workloads that need real-time or high-throughput networking.
* Deploy eBPF-based network policies for identity-aware filtering earlier than traditional iptables rules.
* Attach SLSA/in-toto attestations to production artifacts and firmware update operations for provable provenance.

### Super Root configuration with Cerberus

* Cerberus0 automates the Super Root activation steps through the `DEV` and `SEC` commands.
* Use `DEV` to design and test a Super Root configuration in a dev workspace.
* Use `SEC` to exercise the stack as a chaos test and, on success, promote validated artifacts to the Production Artifacts folder.

### Security and limitations

* VM isolation is strong but not perfect. Pair with CPU microcode and kernel mitigations and practice patch hygiene.
* Privileged bootstrap paths must be audited, constrained, and rotated regularly.
* Treat firmware operations as high-risk workflows – require attestations and limited human approval.

Additional architecture diagrams for software factory pipeline management:

* <img src="https://github.com/Underground-Ops/underground-nexus/blob/cdcb0a3ee862c8c4f029fed6c45fe280786d4173/Graphics/SVG/software-factory-pipeline.svg" alt="Software Factory Pipeline">
* <img src="https://github.com/Underground-Ops/underground-nexus/blob/cdcb0a3ee862c8c4f029fed6c45fe280786d4173/Graphics/SVG/cloud-native-git-bios.svg" alt="Cloud-native Git-BIOS">
* <img src="https://github.com/Underground-Ops/underground-nexus/blob/cdcb0a3ee862c8c4f029fed6c45fe280786d4173/Graphics/SVG/git-bios-engine.svg" alt="Git-BIOS Engine">
* <img src="https://github.com/Underground-Ops/underground-nexus/blob/cdcb0a3ee862c8c4f029fed6c45fe280786d4173/Graphics/SVG/developer-site-architecture.svg" alt="Developer Site Architecture">

---

## Sovereign Kernel Layer: What It Means

* **Sovereign Zone:** a secured environment where **you** own the keys and the control plane. Controls are enforced lower in the stack (hypervisor/network/kernel), not just at the app layer.
* **Agentic kernel:** local + cloud “brains” (agents) operate from **curated artifacts** and your **creed/policy**, automating operations with human approval gates when needed.
* **Evidence by default:** because policy and automations are code, each change can emit attestations and logs suitable for audits.

> **Open-core model:** the FOSS edition exposes the **open core filesystem and artifacts**. Enterprise deployments may run **Nexus OS** (no privileged container; KVM talks directly to OS services) and add private file system + intelligence feeds.

---

## Artifacts, Chaos Testing, and Golden Hosts

* **Artifacts everywhere:** This repository is a **curated artifact set** distilled from real production work and mapped to common controls across global compliance frameworks.
* **Dockerfile as a “chaos test”:** The root **Dockerfile** executes a series of build-time tasks (via `docker exec`), pulling the repo’s artifacts and exercising the stack. Configurations that **survive** are promoted into **Production Artifacts**:
  [https://github.com/Underground-Ops/underground-nexus/tree/main/Production%20Artifacts](https://github.com/Underground-Ops/underground-nexus/tree/main/Production%20Artifacts)
* **Why the activation feels “fragile”:** It’s intentionally a **chaos test**. If something fails on your host, it’s surfacing a network or system constraint early—so you can remediate before trusting production workloads.
* **Golden Host:** A full Nexus deployment is a **living template**—a golden image you can harden further or morph into a **virtual appliance**. Because everything is artifacts, AI/agents can refactor it to your target environment.

**Build appliances with Cerberus:** Use `DEV` to design and `SEC` to validate appliances.

---

## Beginner Mental Model (Windows Analogy)

* Think of the Nexus repository as the **C:\** drive for a **sovereign kernel**.
* **Jelly Apps** are like “Program Files”: sovereign apps installed via **appination** (a small language that places executables on the system **PATH** so they behave like normal commands).
* Because the system is **artifact-driven**, AI/agents can **reshape** it to your needs—one core reason Nexus excels at **GRC** (controls are encoded as artifacts and enforced continuously).

> **Flywheel:** The more controls you encode, the more operations the system can automate and keep in continuous compliance.

---

## Learn More

* **Foundational principles (Cloud-Native & DevSecOps):** [https://gitlab.com/natoascode/nist-draft-regulation-800-204c-comment-notes-and-timestamps](https://gitlab.com/natoascode/nist-draft-regulation-800-204c-comment-notes-and-timestamps)
* **Foundations Nexus was built upon:** [https://notiapoint.com/pages/the-olympiad](https://notiapoint.com/pages/the-olympiad)
* **Start with Cloud Jam Gauntlet:** [https://cloudunderground.dev/products/cloud-jam](https://cloudunderground.dev/products/cloud-jam)

> A great first project is a **sovereign smart home** lab. You’ll learn how to secure, govern, and automate a real environment—then apply the same patterns at work.

---

## Helpful Videos

* **Ditch VPNs: go Zero Trust:** [https://www.youtube.com/watch?v=IYmXPF3XUwo](https://www.youtube.com/watch?v=IYmXPF3XUwo)
* **Publish a Zero Trust WordPress site from Nexus with Cloudflare:** [https://youtu.be/ey4u7OUAF3c](https://youtu.be/ey4u7OUAF3c)

---

### Notes on security stance and modes

* **Open-source route:** privileged runtime to bootstrap/operate the platform from a single container boundary. Constrain with capabilities, SELinux/AppArmor, cgroups, and host namespace controls.
* **Nexus OS (enterprise):** no privileged container; **KVM** talks directly to OS hypervisor services—removes the privileged-container risk class while preserving kernel-level security controls.
* Pair with host hardening and microcode/kernel mitigations as needed.

---

**Docker Desktop is recommended** for developing with Underground Nexus: [https://www.docker.com/products/docker-desktop](https://www.docker.com/products/docker-desktop)

**Natively powered by GitLab and OpenZiti**

* GitLab: [https://about.gitlab.com/](https://about.gitlab.com/)
* OpenZiti: [https://openziti.io/](https://openziti.io/)

---

**Learn to master cloud skills with Underground Nexus — join the Cloud Jam Gauntlet:**
[https://cloudunderground.dev/products/cloud-jam](https://cloudunderground.dev/products/cloud-jam)
