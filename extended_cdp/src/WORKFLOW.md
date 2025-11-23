┌─────────────────────────────────────────────────────────────────────────┐
│                     AEON x402 PAYMENT FLOW                              │
└─────────────────────────────────────────────────────────────────────────┘

STEP 1: GET PAYMENT INFO
━━━━━━━━━━━━━━━━━━━━━━━━
   🤖 ──GET /open/ai/402/payment──▶ 🏪
      ?appId=X&qrCode=X&address=X
   
   🤖 ◀──── HTTP 402 ────────────── 🏪
         {
           "maxAmountRequired": "550000",
           "payTo": "0x302bb...",
           "maxTimeoutSeconds": 60
         }

STEP 2: BUILD X-PAYMENT HEADER
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
   ┌──────────────────────────────┐
   │  authorization = {           │
   │    from: YOUR_WALLET         │  ◀── You provide
   │    to: payTo                 │  ◀── From 402
   │    value: "550000"           │  ◀── From 402
   │    validAfter: NOW           │  ◀── You calculate
   │    validBefore: NOW + 60     │  ◀── From 402 timeout
   │    nonce: 0xRANDOM...        │  ◀── You generate
   │  }                           │
   └──────────────┬───────────────┘
                  ▼
   ┌──────────────────────────────┐
   │  EIP-712 Sign (USDC Domain)  │
   │  ───────────────────────────│
   │  name: "USD Coin"            │
   │  version: "2"                │
   │  chainId: 8453               │
   │  verifyingContract: USDC     │
   └──────────────┬───────────────┘
                  ▼
   ┌──────────────────────────────┐
   │  X-PAYMENT Payload           │
   │  ───────────────────────────│
   │  {                           │
   │    x402Version: 1,           │
   │    scheme: "exact",          │
   │    network: "base",          │
   │    payload: {                │
   │      signature: "0x...",     │
   │      authorization: {...}    │
   │    }                         │
   │  }                           │
   └──────────────┬───────────────┘
                  ▼
            Base64 Encode
                  ▼
         ┌───────────────┐
         │ X-PAYMENT:    │
         │ eyJ4NDAy...   │
         └───────────────┘

STEP 3: SUBMIT PAYMENT
━━━━━━━━━━━━━━━━━━━━━━
   🤖 ──GET + X-PAYMENT header──▶ 🏪
   
   🏪 ──Verify sig──▶ 💰 USDC ──Transfer──▶ ✅
   
   🤖 ◀──── HTTP 200 ────────────── 🏪
         { "status": "SUCCESS" }
