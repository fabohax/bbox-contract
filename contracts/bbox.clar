;; BBOX - Open Bitcoin App Store - Decentralized app listing contract
;; Discover, evaluate, and fund open-source Bitcoin applications through transparent milestones and on-chain contracts

;; ============================================
;; Constants
;; ============================================

(define-constant contract-owner tx-sender)
(define-constant err-owner-only (err u100))
(define-constant err-not-found (err u101))
(define-constant err-unauthorized (err u102))
(define-constant err-already-exists (err u103))
(define-constant err-invalid-fee (err u104))
(define-constant err-payment-failed (err u105))
(define-constant err-invalid-rating (err u106))
(define-constant err-app-not-active (err u107))
(define-constant err-invalid-token (err u108))
(define-constant err-already-voted (err u109))

;; ============================================
;; Data Variables
;; ============================================

(define-data-var admin principal contract-owner)
(define-data-var listing-fee-sbtc uint u111111) ;; 111111 satoshis in sBTC
(define-data-var app-id-nonce uint u0)
(define-data-var total-apps uint u0)

;; ============================================
;; Data Maps
;; ============================================

;; Main app registry - stores essential on-chain data
;; All descriptive metadata (name, description, URLs, etc.) stored in IPFS
(define-map apps
  { app-id: uint }
  {
    ;; Publisher Info
    publisher: principal,
    
    ;; IPFS Metadata (contains: name, description, category, version, URLs, 
    ;; license, pricing, publisher info, images, etc.)
    ipfs-hash: (string-ascii 100),
    
    ;; Status & Verification
    status: (string-ascii 20), ;; pending, active, suspended
    verified: bool,
    featured: bool,
    
    ;; Engagement Metrics
    total-votes: uint,
    positive-votes: uint,
    rating-sum: uint,
    rating-count: uint,
    
    ;; Timestamps
    created-at: uint,
    updated-at: uint
  }
)

;; Map publisher to their app IDs
(define-map publisher-apps
  { publisher: principal }
  { app-ids: (list 100 uint) }
)

;; Track user votes on apps (one vote per user per app)
(define-map user-votes
  { voter: principal, app-id: uint }
  { 
    vote-type: (string-ascii 10), ;; upvote, downvote
    voted-at: uint 
  }
)

;; Track user ratings on apps (mutable - users can update their ratings)
(define-map user-ratings
  { voter: principal, app-id: uint }
  { 
    rating: uint,  ;; 1-5 stars
    rated-at: uint,
    updated-at: uint
  }
)

;; ============================================
;; Private Functions
;; ============================================

(define-private (is-admin (caller principal))
  (is-eq caller (var-get admin))
)

(define-private (is-app-owner (caller principal) (app-id uint))
  (match (map-get? apps { app-id: app-id })
    app-data (is-eq caller (get publisher app-data))
    false
  )
)

(define-private (increment-app-nonce)
  (let ((current-nonce (var-get app-id-nonce)))
    (var-set app-id-nonce (+ current-nonce u1))
    current-nonce
  )
)

(define-private (process-listing-fee (payer principal))
  (let ((fee (var-get listing-fee-sbtc)))
    (if (> fee u0)
      ;; Transfer sBTC from payer to admin
      (match (contract-call? 'ST1PQHQKV0RJXZFY1DGX8MNSNYVE3VGZJSRTPGZGM.sbtc-token transfer 
        fee 
        payer 
        (var-get admin) 
        none)
        success (ok true)
        error (err err-payment-failed)
      )
      (ok true)
    )
  )
)

;; ============================================
;; Public Functions - App Management
;; ============================================

;; Submit a new app listing
;; All descriptive data should be in the IPFS metadata JSON
(define-public (submit-app (ipfs-hash (string-ascii 100)))
  (let
    (
      (app-id (increment-app-nonce))
      (caller tx-sender)
      (current-block stacks-block-height)
    )
    ;; Process listing fee
    (try! (process-listing-fee caller))
    
    ;; Create app entry with minimal on-chain data
    (map-set apps
      { app-id: app-id }
      {
        publisher: caller,
        ipfs-hash: ipfs-hash,
        status: "pending",
        verified: false,
        featured: false,
        total-votes: u0,
        positive-votes: u0,
        rating-sum: u0,
        rating-count: u0,
        created-at: current-block,
        updated-at: current-block
      }
    )
    
    ;; Add to publisher's app list
    (match (map-get? publisher-apps { publisher: caller })
      existing-apps 
        (map-set publisher-apps 
          { publisher: caller }
          { app-ids: (unwrap-panic (as-max-len? (append (get app-ids existing-apps) app-id) u100)) }
        )
      (map-set publisher-apps
        { publisher: caller }
        { app-ids: (list app-id) }
      )
    )
    
    ;; Increment total apps
    (var-set total-apps (+ (var-get total-apps) u1))
    
    (ok app-id)
  )
)

;; Update app metadata (only updates IPFS hash - all content changes go through IPFS)
(define-public (update-app-metadata
    (app-id uint)
    (new-ipfs-hash (string-ascii 100))
  )
  (let ((app-data (unwrap! (map-get? apps { app-id: app-id }) err-not-found)))
    (asserts! (is-app-owner tx-sender app-id) err-unauthorized)
    
    (map-set apps
      { app-id: app-id }
      (merge app-data {
        ipfs-hash: new-ipfs-hash,
        updated-at: stacks-block-height
      })
    )
    (ok true)
  )
)

;; ============================================
;; Public Functions - Voting & Rating
;; ============================================

;; Vote on an app (upvote/downvote) - one vote per user, immutable
(define-public (vote-app
    (app-id uint)
    (vote-type (string-ascii 10))
  )
  (let
    (
      (app-data (unwrap! (map-get? apps { app-id: app-id }) err-not-found))
      (voter tx-sender)
      (current-block stacks-block-height)
      (is-upvote (is-eq vote-type "upvote"))
    )
    ;; Check if app is active
    (asserts! (is-eq (get status app-data) "active") err-app-not-active)
    
    ;; Check if user has already voted
    (asserts! (is-none (map-get? user-votes { voter: voter, app-id: app-id })) err-already-voted)
    
    ;; Record vote (immutable)
    (map-set user-votes
      { voter: voter, app-id: app-id }
      {
        vote-type: vote-type,
        voted-at: current-block
      }
    )
    
    ;; Update app vote counts
    (map-set apps
      { app-id: app-id }
      (merge app-data {
        total-votes: (+ (get total-votes app-data) u1),
        positive-votes: (if is-upvote 
          (+ (get positive-votes app-data) u1) 
          (get positive-votes app-data)
        ),
        updated-at: current-block
      })
    )
    
    (ok true)
  )
)

;; Rate an app (1-5 stars) - can be updated by user
(define-public (rate-app
    (app-id uint)
    (rating uint)
  )
  (let
    (
      (app-data (unwrap! (map-get? apps { app-id: app-id }) err-not-found))
      (voter tx-sender)
      (current-block stacks-block-height)
      (existing-rating (map-get? user-ratings { voter: voter, app-id: app-id }))
    )
    ;; Validate rating
    (asserts! (and (>= rating u1) (<= rating u5)) err-invalid-rating)
    (asserts! (is-eq (get status app-data) "active") err-app-not-active)
    
    ;; Handle rating update or new rating
    (match existing-rating
      old-rating
        (begin
          ;; Update existing rating
          (map-set user-ratings
            { voter: voter, app-id: app-id }
            {
              rating: rating,
              rated-at: (get rated-at old-rating),
              updated-at: current-block
            }
          )
          ;; Adjust rating sum (remove old, add new)
          (map-set apps
            { app-id: app-id }
            (merge app-data {
              rating-sum: (+ (- (get rating-sum app-data) (get rating old-rating)) rating),
              updated-at: current-block
            })
          )
        )
      ;; New rating
      (begin
        (map-set user-ratings
          { voter: voter, app-id: app-id }
          {
            rating: rating,
            rated-at: current-block,
            updated-at: current-block
          }
        )
        ;; Add new rating
        (map-set apps
          { app-id: app-id }
          (merge app-data {
            rating-sum: (+ (get rating-sum app-data) rating),
            rating-count: (+ (get rating-count app-data) u1),
            updated-at: current-block
          })
        )
      )
    )
    
    (ok true)
  )
)

;; ============================================
;; Admin Functions
;; ============================================

;; Approve an app (change status to active)
(define-public (approve-app (app-id uint))
  (let ((app-data (unwrap! (map-get? apps { app-id: app-id }) err-not-found)))
    (asserts! (is-admin tx-sender) err-owner-only)
    
    (map-set apps
      { app-id: app-id }
      (merge app-data {
        status: "active",
        updated-at: stacks-block-height
      })
    )
    (ok true)
  )
)

;; Suspend an app
(define-public (suspend-app (app-id uint))
  (let ((app-data (unwrap! (map-get? apps { app-id: app-id }) err-not-found)))
    (asserts! (is-admin tx-sender) err-owner-only)
    
    (map-set apps
      { app-id: app-id }
      (merge app-data {
        status: "suspended",
        updated-at: stacks-block-height
      })
    )
    (ok true)
  )
)

;; Mark app as verified
(define-public (verify-app (app-id uint) (verified bool))
  (let ((app-data (unwrap! (map-get? apps { app-id: app-id }) err-not-found)))
    (asserts! (is-admin tx-sender) err-owner-only)
    
    (map-set apps
      { app-id: app-id }
      (merge app-data {
        verified: verified,
        updated-at: stacks-block-height
      })
    )
    (ok true)
  )
)

;; Feature an app
(define-public (feature-app (app-id uint) (featured bool))
  (let ((app-data (unwrap! (map-get? apps { app-id: app-id }) err-not-found)))
    (asserts! (is-admin tx-sender) err-owner-only)
    
    (map-set apps
      { app-id: app-id }
      (merge app-data {
        featured: featured,
        updated-at: stacks-block-height
      })
    )
    (ok true)
  )
)

;; Update listing fee in sBTC
(define-public (update-listing-fee-sbtc (new-fee uint))
  (begin
    (asserts! (is-admin tx-sender) err-owner-only)
    (var-set listing-fee-sbtc new-fee)
    (ok true)
  )
)

;; Transfer admin ownership
(define-public (transfer-admin (new-admin principal))
  (begin
    (asserts! (is-admin tx-sender) err-owner-only)
    (var-set admin new-admin)
    (ok true)
  )
)

;; ============================================
;; Read-Only Functions
;; ============================================

;; Get app details by ID
(define-read-only (get-app (app-id uint))
  (map-get? apps { app-id: app-id })
)

;; Get apps by publisher
(define-read-only (get-publisher-apps (publisher principal))
  (map-get? publisher-apps { publisher: publisher })
)

;; Get user vote on an app
(define-read-only (get-user-vote (voter principal) (app-id uint))
  (map-get? user-votes { voter: voter, app-id: app-id })
)

;; Get user rating on an app
(define-read-only (get-user-rating (voter principal) (app-id uint))
  (map-get? user-ratings { voter: voter, app-id: app-id })
)

;; Check if user has voted on an app
(define-read-only (has-user-voted (voter principal) (app-id uint))
  (is-some (map-get? user-votes { voter: voter, app-id: app-id }))
)

;; Check if user has rated an app
(define-read-only (has-user-rated (voter principal) (app-id uint))
  (is-some (map-get? user-ratings { voter: voter, app-id: app-id }))
)

;; Get current listing fee
(define-read-only (get-listing-fee)
  { token: "sBTC", amount: (var-get listing-fee-sbtc) }
)

;; Get admin address
(define-read-only (get-admin)
  (var-get admin)
)

;; Get total number of apps
(define-read-only (get-total-apps)
  (var-get total-apps)
)

;; Get current app ID nonce
(define-read-only (get-app-id-nonce)
  (var-get app-id-nonce)
)

;; Calculate average rating for an app
(define-read-only (get-app-rating (app-id uint))
  (match (map-get? apps { app-id: app-id })
    app-data 
      (if (> (get rating-count app-data) u0)
        (some (/ (get rating-sum app-data) (get rating-count app-data)))
        none
      )
    none
  )
)

;; Get app vote percentage
(define-read-only (get-app-vote-percentage (app-id uint))
  (match (map-get? apps { app-id: app-id })
    app-data 
      (if (> (get total-votes app-data) u0)
        (some (/ (* (get positive-votes app-data) u100) (get total-votes app-data)))
        none
      )
    none
  )
)

;; Check if app is verified
(define-read-only (is-app-verified (app-id uint))
  (match (map-get? apps { app-id: app-id })
    app-data (get verified app-data)
    false
  )
)

;; Check if app is featured
(define-read-only (is-app-featured (app-id uint))
  (match (map-get? apps { app-id: app-id })
    app-data (get featured app-data)
    false
  )
)
