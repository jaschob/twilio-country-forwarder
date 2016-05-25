# Little forwarder app for SMS and Voice, for traveling

config = require("config")
express = require("express")
twilio = require("twilio")
body_parser = require("body-parser")
mailer = require("nodemailer")
app = express()

re_forward_instruction = new RegExp(/([+][0-9]+): *(.+)/)

# init Twilio API client
twilio_client = new twilio.RestClient(
    config.get("twilio.account_sid"),
    config.get("twilio.auth_token"))

# init email client
smtp = mailer.createTransport(config.get("email"))

# helpers
is_forwardable = (did) ->
    forwardable_dids = config.get("forwardable_dids")
    did in forwardable_dids

on_sent_sms = (res, error, message) ->
    if error
        console.log("Uh oh, error: #{error}")
        res.status(500).json(
            error: error)
    else
        console.log("SMS sent: #{message.sid}")
        res.status(201).end()

on_sent_email = (error, response) ->
    if error
        console.log("Uh-oh, error sending email: #{error}")
    else
        console.log("Success sending email :-)")

send_message = (from, to, body, cb) ->
    twilio_client.messages.create(
        body: body,
        to: to,
        from: from,
        cb)

send_email = (from, to, subject, body, cb) ->
    smtp.sendMail(
        from: from,
        to: to,
        subject: subject,
        text: body,
        cb)

send_recording_email = (call_sid, call_from, recording_url, duration) ->
    email_from = "Number Forwarder <no-reply@jaschob.de>"
    email_to = config.get("owner.name") + " <" + config.get("owner.email") + ">"
    subject = "[Number Forwarder] New Recording Saved From #{call_from}"
    body = "A new recording has been saved for: #{call_sid}\n" +
        "Retrieve it here: #{recording_url}.\n" +
        "\n" +
        "Duration: #{duration} second(s)"

    send_email(email_from, email_to, subject, body, on_sent_email)

send_transcription_email = (sid, text, status, url, call_sid) ->
    email_from = "Number Forwarder <no-reply@jaschob.de>"
    email_to = config.get("owner.name") + " <" + config.get("owner.email") + ">"
    subject = "[Number Forwarder] New Transcription Arrived"
    body = "A new transcription is ready for #{call_sid}: #{sid} (status: #{status})\n" +
        "Retrieve it here: #{url}.\n" +
        "\n" +
        text

    send_email(email_from, email_to, subject, body, on_sent_email)

# various handlers
on_incoming_sms = (twilio_client, req, res) ->
    sid = req.body.MessageSid
    from = req.body.From
    twilio_to = req.body.To
    body = req.body.Body        # ugh
    console.log("Incoming SMS: #{sid} (from #{from}).")

    forward_info = body.match(re_forward_instruction)
    if forward_info
        forward_to = forward_info[1]
        forward_message = "#{from}: #{forward_info[2]}"

        if is_forwardable(from)
            console.log("Outgoing message, forwarding to #{forward_to}...")
            send_message twilio_to, forward_to, forward_message,
                (error, message) -> on_sent_sms(res, error, message)
        else
            console.log("DID #{from} is not allowed to forward!")
            res.status(401).end()
    else
        console.log("Incoming message, sending to owner...")
        forward_to = config.get("owner.did")
        forward_message = "#{from}: #{body}"
        send_message twilio_to, forward_to, forward_message,
            (error, message) -> on_sent_sms(res, error, message)

on_incoming_call = (req, res) ->
    sid = req.body.CallSid
    from = req.body.From
    console.log("Got call #{sid} from #{from}.")

    twiml = new twilio.TwimlResponse()
    twiml.say(
        "Sie haben die Mailbox von Michael Jaschob erreicht. " +
        "Bitte hinterlassen sie eine Nachricht nach dem Ton. Danke!",
        language: "de-DE")
    twiml.record(
        playBeep: true,
        maxLength: 360,
        action: "/voice/recorded") #,
        #transcribe: true,
        #transcribeCallback: "/voice/transcribed")
        # transcription suck for German :-(
    res.send(twiml)

on_incoming_recording = (req, res) ->
    call_sid = req.body.CallSid
    call_from = req.body.From
    recording_url = req.body.RecordingUrl
    duration = req.body.RecordingDuration
    digits = req.body.Digits
    owner_did = config.get("owner.did")
    sms_did = config.get("twilio.sms_did")

    console.log("New recording at #{recording_url} from #{call_from} (#{duration} seconds) [#{digits}]")
    send_recording_email call_sid, call_from, recording_url, duration
    send_message sms_did, owner_did, "#{call_from} left message at #{recording_url} (#{duration} seconds)",
        (error, message) -> on_sent_sms(res, error, message)

on_incoming_transcription = (req, res) ->
    sid = req.body.TranscriptionSid
    text = req.body.TranscriptionText
    status = req.body.TranscriptionStatus
    url = req.body.TranscriptionUrl
    call_sid = req.body.CallSid

    console.log("Transcription #{sid} for #{call_sid} with statys #{status}.")
    console.log("Retrieve at #{url}")
    console.log(text)
    send_transcription_email sid, text, status, url, call_sid

# configure, hook up routes
app.use(body_parser.json());
app.use(body_parser.urlencoded({ extended: true }))

app.post("/sms/incoming", (req, res) ->
    on_incoming_sms(twilio_client, req, res))
app.post("/voice/incoming", twilio.webhook({validate: false}),
    on_incoming_call)
app.post("/voice/recorded", twilio.webhook({validate: false}),
    on_incoming_recording)
app.post("/voice/transcribed", twilio.webhook({validate: false}),
    on_incoming_transcription)

# listen on port 3000
app.listen(3000, () ->
    console.log("Server started and listening"))
