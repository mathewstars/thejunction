# Valio Aimo: Trusted Trade Agents

Our challenge for Junction 2026. This is our summary of the brief on the Junction platform (hackjunction.app, Challenges, "Trusted Trade Agents", needs a login). Read the original before you build against a detail.

## The question

How can a food-service wholesaler let autonomous purchasing agents place an order (find products, compare offers, get the right approval) in a fraction of the time it takes today, without exposing real systems, confidential data or the marketplace roadmap?

## Who asks

Valio Aimo is the food-service wholesale arm of Valio: 20,000 professional kitchens, 25,000 products, 700 suppliers. They plan a digital B2B marketplace. For Junction they mock today's webshop and backend, not the marketplace.

They want the **interface and operating model** through which an external purchasing agent could work with their systems, built on open, verifiable standards and not on one platform's black box. It is not a chatbot on top of the webshop.

## What the solution must do (core)

1. **Product, price and availability lookup.** A structured way for an external agent to search and retrieve what is available and at what price.
2. **From inquiry to order.** A defined interaction from asking for price and availability to placing the order. Prices are fixed, there is no negotiation.
3. **Permissions and human approval.** What the agent may decide alone and what must go to a human for sign-off.

## Optional directions (not needed to win)

- Compare delivery time and sustainability labels, not only price. Category-level carbon footprint is a stretch goal.
- Substitutions and other exceptions when the exact request cannot be met.
- Traceability: a human-readable record of what the agent did and why.

## Their example request

"I need 1,000 litres of lactose-free milk by Monday. Find an option that meets our requirements based on price and availability."

A hotel chain's agent sends this. The solution returns products, prices and availability in structured form. The agent places the order within its authority or sends it to a human for approval.

## Problems they would love to see tackled

- **Trust protocol:** the minimum data and verification standard for an external agent to trust Valio Aimo's claims on stock, price and origin without a manual check.
- **Guardrails model:** which decisions need human sign-off (spend threshold, substitutions outside stated preferences) and which are fully autonomous.
- **Response logic:** partial availability and substitution ranking ("good, better, best") inside Valio Aimo's own assortment.
- **Audit trail:** a usable, human-readable log of the agent's purchasing decisions, for the buyer and for Valio Aimo.

## Scenarios they list

- Need, recipe, order: a chef plans a menu around a seasonal ingredient; the agent suggests recipes, works out what is missing and orders it.
- Last-minute event: a booking for tomorrow; the agent flags what cannot be sourced in time and proposes substitutions through recipe logic.
- Supplier stock-out: the agent proposes a recipe-compatible substitute before the kitchen notices, and explains the trade-off.
- Proactive selling agent: Valio Aimo's own agent suggests a new or seasonal product to the buyer's agent.
- Allergen-safe substitution in a school or hospital kitchen.
- Standing order drift: the agent learns a weekly order and flags anomalies before it renews it.

## Judging

| Criterion | Weight | What they look at |
|---|---|---|
| Working end-to-end demo | 30% | The full flow request, lookup, order or approval runs in the mocked environment, not isolated pieces |
| Solving the problem and user need | 20% | How precisely the agent matches what the buyer asked for, with the least manual correction |
| Autonomy and controls | 20% | Quality of the guardrails: what the agent decides alone, what needs sign-off, how decisions are logged and auditable |
| Robustness to exceptions | 15% | Partial availability, substitutions and delivery constraints beyond the happy path |
| Openness and path to production | 15% | Open, documented standards, visible assumptions, justified technical choices, credible next steps |

## Prizes

1st 4,000 €, 2nd 2,000 €, 3rd 1,000 €.

## What they provide

- A synthetic product catalog, simulated suppliers and mock APIs that mimic the webshop and backend: prices, availability behaviour, delivery lead times, sustainability certificates and labels.
- A resource portal with datasets, API documentation and instructions for the mock backend: https://junction26.valioaimo.fi/
- Mentors for marketplace and commercial questions, online sales, and IT integrations and data governance.
- Webshop test accounts, to be shared separately.

**The portal password and the API key are on the challenge page. Do not copy them into this repo, it is public.** Put them in `.env` (git-ignored).

All data is synthetic. No production systems or confidential data are involved.

## Scope notes from the brief

- Preferred tech: AI agents with tool use, open data and interoperability standards, recommendation logic, optional verifiable credentials or a trust layer. Agentic payment standards (x402, Nevermined) are context, not a requirement.
- Whether the production interface becomes a classic API, an MCP-style interface or a service agent of their own is out of scope. We mock a structured data interface.
- Last year's challenge covered failed deliveries in depth, so substitution handling is not scored as core.
