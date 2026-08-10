# FEC-hackathon
# 🛡️ BlindGrant

Private, milestone-based grant escrow for anonymous academic & DAO bounties. Built for the Road to Devcon Hackathon — DeFi Vertical, Finance and Economics Club, IIT Guwahati.

- **Live demo:** `https://lucius145.github.io/FEC-hackathon/index.html`
- **Demo video:** `<link>`
- **Contract (Sepolia):** `0xBB8A82De585515789E848C2E90870ded5660D5e6`

## Problem

Accepting a bounty payout on-chain permanently links a worker's wallet to that payment — doxxing their entire transaction history. Sponsors also can't verify eligibility without either exposing the applicant or trusting an unverifiable off-chain claim.

## Solution

BlindGrant escrows a grant on-chain and uses a Semaphore zero-knowledge identity so a worker can prove they're an eligible, registered member of a grant's applicant group — and submit a payout claim — without revealing which registered identity they are.

## How It Works

1. **`createGrant`** — sponsor deposits ETH and posts a task brief; creates a fresh Semaphore group for the grant.
2. **`joinGrantGroup`** — worker publishes a Semaphore identity commitment (generated client-side from a wallet signature) to register.
3. **`submitWork`** — worker generates a ZK proof of group membership and submits it with a payout address and a work-proof link.
4. **`approvePayout`** — sponsor releases funds to the payout address on file. **`rejectWork`** reopens the grant; **`cancelGrant`** refunds the sponsor if unclaimed.

## Privacy Technology: Semaphore (V4)

Semaphore proves group membership without revealing which member — the core privacy primitive here.

| Concept | Role in BlindGrant |
|---|---|
| Identity / commitment | Generated client-side from a wallet signature; private key never leaves the browser, only the public commitment is published. |
| Group | Each grant gets its own Semaphore group of registered workers. |
| Zero-knowledge proof | Proves membership in a grant's group without revealing which identity. |
| Nullifier | Enforces one submission per identity per grant, without linking submissions to identities. |
| Scope | Set to the grant's `groupId`, so a proof from one grant can't be replayed against another. |
| Message | Set to the worker's payout address, binding it into the proof itself — prevents a mempool observer from copying a valid proof and swapping in their own payout address. |

Semaphore was chosen over Railgun/Privacy Pools because the problem here is hiding **who** is claiming a grant, not the grant **amount** — an identity-privacy problem, not a payments-privacy one.
