# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

XertiQ is a blockchain-based document verification and certificate issuance platform. It enables organizations to issue digital certificates anchored on the Solana blockchain and allows users to verify document authenticity.

**Tech Stack:**
- Frontend: React 19, Vite, Tailwind CSS, Zustand (state management)
- Backend: Express.js 5, Prisma ORM, PostgreSQL
- Blockchain: Solana Web3.js (Devnet for development)
- Storage: IPFS via Pinata
- Payments: Stripe, PayMongo

## Common Commands

### Frontend (xertiq_frontend/)
```bash
npm run dev       # Development server at http://localhost:5173
npm run build     # Production build to dist/
npm run lint      # ESLint check
npm run preview   # Preview production build
```

### Backend (xertiq_backend/)
```bash
npm run dev       # Development with nodemon on PORT 3000
npm start         # Production server

# Database (Prisma)
npm run db:generate     # Generate Prisma client
npm run db:push         # Push schema changes
npm run db:migrate:dev  # Create new migration
npm run db:studio       # Open Prisma Studio GUI
npm run db:seed         # Seed test data
npm run reset           # Force reset DB and reseed
```

## Architecture

### Monorepo Structure
- `xertiq_frontend/` - React SPA, also builds as Chrome Extension
- `xertiq_backend/` - Express.js REST API
- `docs/` - Embeddable verification widget

### Key Data Flow

**Certificate Batch Processing:**
1. Upload CSV (identityEmail, birthday, gender, metadata) + PDF files
2. Encrypt and upload PDFs to IPFS (Pinata)
3. Generate identity hashes: `SHA256(email_birthday_gender)` - no PII on blockchain
4. Build Merkle tree from `SHA256(identityString + "|" + ipfsCID)`
5. Anchor merkleRoot to Solana in single transaction
6. Store individual document holder transactions
7. Generate display PDFs with QR verification codes

**Verification Flow:**
- User scans QR or visits `/verify?doc={docId}`
- Backend retrieves BatchDocument and reconstructs Merkle proof
- Verifies merkleRoot against blockchain transaction

### Database Models (Prisma)
- `User` - Roles: USER, ADMIN, ISSUER, VALIDATOR, SUPER_ADMIN
- `Batch` - Merkle tree batches anchored to Solana
- `BatchDocument` - Individual documents with proofPath for verification
- `CreditWallet` / `CreditTransaction` - Credit-based payment system
- `Template` - Reusable JSON-based certificate designs
- `AuditLog` - SOC 2 / GDPR compliance logging

### Credit System Costs
- PDF Generation: 2 credits
- IPFS Upload: 1 credit
- Blockchain Upload: 3 credits
- Certificate Validation: 1 credit

## Environment Variables

### Backend (.env)
```
DATABASE_URL, JWT_SECRET, JWT_EXPIRES_IN
SOLANA_RPC_URL, SOLANA_PRIVATE_KEY
PINATA_API_KEY, PINATA_SECRET_API_KEY
STRIPE_SECRET_KEY, PAYMONGO_SECRET_KEY
RESEND_API_KEY
```

### Frontend (.env)
```
VITE_API_BASE_URL=http://localhost:3000/api
```

## Key Patterns

- JWT authentication with 7-day expiry, verified via `middleware/auth.js`
- Role-based access control checked in route middleware
- SSE (Server-Sent Events) for real-time batch processing progress
- All user actions logged to AuditLog for compliance
- PII stays in database only; blockchain stores only SHA256 hashes
