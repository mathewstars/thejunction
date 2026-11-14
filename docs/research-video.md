# Research video (separate from the main pitch video)

A short second video that explains only the research idea: can a phone notice when someone is getting worse again? It is for the research track and for anyone who has never heard of a PHQ-9. The main two-minute pitch video is a different piece and is not covered here.

Status on Sunday 15 November, 04:30: there is ONE film, the submission video, locked as v14 (1:43). The story of Anna and the fox carries it, and the product sits inside the story. The older plan is kept below for its prompts and wording rules; the research chart it describes is no longer in the film.

## The submission film (v14)

| # | Voice | Picture |
|---|---|---|
| 1 | Anna's treatment for depression is over. The next appointment is six weeks away. | She walks out of the clinic; gloved hands with the appointment card (generated) |
| 2 | On the way home, she finds a fox cub, alone in the snow. She picks him up. And he steps into her phone. | One continuous shot of her finding and lifting the cub; the cub turns to light and flows into her phone (generated); then the real app |
| 3 | Every day she does one small thing for him. Some days, she would stay in bed. For him, she gets up. | The real app; one continuous shot of her getting out of bed and opening the curtain (generated) |
| 4 | This is not a habit tracker. She said yes. | Text card |
| 5 | While she plays, the phone reads how her face moves, thirty times a second. Numbers only, never pictures. | Left: the real app in the focus game. Right: "What leaves the phone", ten face channels as live bars and the rows as sent |
| 6 | At the clinic, rules notice a change. Two models weigh in. Code checks every claim, and drops what the numbers don't support. | "One game session, read": the trace of the mouth corners, the three steps, two reported smiles confirmed and one dropped, and the counts of one real run (3 reported, 2 confirmed, 1 dropped) |
| 7 | In November, hard days return. At one a.m. she writes: I need help. | She sits on the bed edge; the phone at night (generated) |
| 8 | Her words reach her clinic. Next morning, her nurse calls. Anna, I read your note. I'm here. | The nurse with the real Telegram alert over the shot; morning; the nurse on the phone with the real clinician page beside her; Anna on the phone (footage generated) |
| 9 | This time, she doesn't wait six weeks. | She walks back to the clinic, the fox beside her (generated) |
| 10 | Lanvi. The fox you rescue keeps the light on for you. | The fox logo and the motto, then black |

Every spoken line is subtitled. Generated footage carries the label "Illustrative footage, generated"; the two drawn screens say that they use an example session with generated numbers.

How it is built (`video/`): `build14.py` holds the shot list keyed to the soundtrack, the subtitles, the corner logo and the fade. It enforces two rules: a clip is shown once only, and every footage shot runs four seconds or more at natural speed. `anim.py` draws screens 5 and 6 from one session of the engine's reference generator (`clinic_engine.frames_reference.make_session(7)`). `script_v13.txt` is the narration as given to Suno: one paragraph per sentence, because a paragraph break is what Suno Speech pauses on. Not in the repository: the generated stills and clips (Higgsfield), the soundtrack (one Suno Speech take, with the last line re-read by Suno's Extend of the same recording), and the simulator recordings of the app.

## What it must do

- One idea, understood by someone with no medical background, in 60 to 75 seconds.
- Say plainly that the data is example data and that the answer is not known.
- End on the question we want to study, not on a claim.

## Length and shape

| Part | Time | What carries it |
|---|---|---|
| 1. The gap | 0:00 to 0:12 | Generated footage |
| 2. The phone is there | 0:12 to 0:22 | Generated footage, then the real app |
| 3. What we compare | 0:22 to 0:40 | Real screen: Blueprint, "The research" |
| 4. Two answers | 0:40 to 0:58 | Real screen: Anna's Research, then Elina's |
| 5. The open question | 0:58 to 1:12 | Real screen, then the question as text |

Rule for the whole video: **generated footage tells the story, real screen recordings carry every piece of evidence.** No generated app screens, charts or patients presented as real.

## Script

**1. The gap (0:00 to 0:12)**

> After treatment for depression, people go home. The clinic sees them again in weeks. A lot can change in weeks.

**2. The phone is there (0:12 to 0:22)**

> One thing is with them every day: their phone. It already knows how much they walk. In a short game it can also count how often they smile and how fast they react. Numbers only. No pictures leave the phone.

**3. What we compare (0:22 to 0:40)**

> Clinics measure depression with a nine-question score, from 0 to 27. We put the two side by side, week by week, for one person. [the two-line picture] The score, and her smiling. When one goes up, does the other follow?

**4. Two answers (0:40 to 0:58)**

> This is Anna, an example. When her score was higher, she smiled less, reacted more slowly and walked less. The tool is careful even here: partly consistent, low confidence, because thirteen scores are few. [switch] And this is Elina, who stayed well. Her score hardly moved, and the tool says: we cannot tell. Here it refuses to conclude.

**5. The open question (0:58 to 1:12)**

> This is example data. Whether a phone can really see this, and whether it sees it first, nobody knows yet. That is the study we want to run: thirty people, twelve weeks, one question. Can the phone tell the clinic before the next appointment does?

## Shots to generate (for Higgsfield or a similar tool)

Keep every shot 3 to 5 seconds, no faces in close-up, no text in the image, natural light, calm, slow or no camera movement. Style line to add to every prompt: *"documentary, natural light, muted colours, shallow depth of field, no text, no logos"*.

| # | Used in | Prompt |
|---|---|---|
| G1 | Part 1 | A woman in a winter coat walks out through the glass door of a small modern clinic in a Nordic town, seen from behind, late autumn afternoon, the door closes slowly behind her. |
| G2 | Part 1 | An empty clinic waiting room with four chairs and a plant, late afternoon light through blinds, nobody there, static shot. |
| G3 | Part 1 | A wall calendar in a hallway with one date circled weeks ahead, soft daylight, slow push in. |
| G4 | Part 2 | A phone lying on a wooden bedside table next to a glass of water, early morning light, the screen lights up softly, static shot. |
| G5 | Part 2 | Close on hands holding a phone in a kitchen, thumb tapping the screen in a calm rhythm, face not visible, morning light. |

Do not generate: the app, the fox, the clinic page, any chart, any doctor looking at a screen with data, any face presented as a patient.

## Generating the shots on higgsfield.ai (copy and paste)

Use the website, not the command-line tool. Higgsfield's own page says unlimited access and free generations apply only on higgsfield.ai; anything made through the CLI is charged in credits.

Two steps per shot: first a still image, then that image turned into a 5-second clip. Making the still first lets you reject a bad frame before spending time on video.

**Settings for every shot**

| Setting | Value |
|---|---|
| Aspect ratio | 16:9 |
| Still image model | the photo-realistic image model (Higgsfield's page names Nano Banana Pro) |
| Video model | image to video with a start image (their page names Seedance 2.5) |
| Clip length | 5 seconds |
| Resolution | 1080p |
| Camera | static or one slow move; no cuts inside a clip |

Model names are as given on Higgsfield's page on 14 Nov 2026; use whatever the site offers under those roles.

**Add this line to the end of every still prompt:**

> documentary photograph, natural window light, muted colours, shallow depth of field, 35mm lens, no text, no logos, no watermark

**G1. The door closes**

- Still: `A woman in a dark winter coat seen from behind, walking out through the glass door of a small modern clinic in a Nordic town, late autumn afternoon, wet pavement, bare birch trees, the door half open behind her.`
- Motion: `She walks away from the camera; the glass door swings slowly shut behind her. Static camera.`

**G2. Nobody there**

- Still: `An empty clinic waiting room with four simple chairs and one green plant, late afternoon light through half-closed blinds drawing stripes on the floor, nobody in the room.`
- Motion: `Almost still. Dust drifts in the light; the stripes of light move very slightly. Static camera.`

**G3. Weeks until the next visit**

- Still: `A paper wall calendar in a hallway at home, one date several weeks ahead circled by hand in pen, soft daylight from the side, a coat hook at the edge of the frame.`
- Motion: `Very slow push in towards the circled date.`

**G4. The phone is there**

- Still: `A phone lying face up on a wooden bedside table beside a glass of water, early morning, grey-blue light, bed linen out of focus behind it, the phone screen dark.`
- Motion: `The phone screen lights up softly and lights the table. Static camera.`

**G5. One small thing a day**

- Still: `Close view of two hands holding a phone above a kitchen table, a mug beside them, morning light, the person's face out of frame, the phone screen turned away from the camera.`
- Motion: `One thumb taps the screen in a calm, slow rhythm. Static camera.`

**Check each result before keeping it**

- No face in close-up, and nobody who could be taken for a real patient.
- No readable text, signs or logos anywhere in the frame. Generated text is always wrong and gives the clip away.
- The phone screen never shows an app. Our real screens are recorded, never generated.
- Hands have five fingers. Reject and regenerate if not.
- There is no shot of her walking again (the earlier G6 is dropped): it suggests a recovery we have not shown.

## Shots to record from the real system

| # | Used in | What to record |
|---|---|---|
| R1 | Part 2 | The phone with Lanvi on the home screen, then five seconds of the focus game. |
| R2 | Part 3 | lanvi.app, Blueprint, "The research": the three boxes, then the panel "What moving together looks like". Scroll slowly; pause on the two lines. |
| R3 | Part 3 | The same page: the yardstick bar from 0 to 27. Two seconds. |
| R4 | Part 4 | Anna's Research page: the headline (it reads "partly consistent" with low confidence; say so), then the chart. Move the cursor along the shaded weeks. |
| R5 | Part 4 | Elina's Research page: the headline "too little change to tell", then her flat line under the cut-off. |
| R6 | Part 5 | Blueprint, the panel "Do the phone's numbers change first?". |

Record at the laptop's normal window size, zoom the browser to 110 % so text survives video compression, hide bookmarks, and sign in before recording so no login appears.

## On screen text

- From part 3 to the end, bottom left, small: "Example data".
- Over the generated shots, bottom left, small: "Illustrative footage, generated".
- Last frame: the question on its own line, "Can the phone tell the clinic before the next appointment does?", then the project name.

## What not to say

- Not "detects depression", not "predicts relapse", not "diagnoses".
- Not "the AI understands emotions". The phone counts smiles; a questionnaire measures depression; we compare the two.
- No numbers the viewer cannot place. "She smiled less" is enough; the page has the figures for anyone who asks.

## Before using generated footage

Check the Junction rules on generated media. We know the limit for the main video is 2:00; we have not seen a rule either way on generated footage. If in doubt, parts 1 and 5 work with a plain dark background and the sentences as text.
