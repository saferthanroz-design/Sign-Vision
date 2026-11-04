# Starter model goes here

Before the first build, copy the starter model into this folder as
`starter_samples.json`:

```sh
cp ~/workspace/isl_sign_voice/model/starter_samples.json \
   ~/workspace/signvoice_app/assets/model/starter_samples.json
```

It is the identical file the web prototype uses (24 ISL alphabet signs,
706 samples, canonical 128-float feature layout). It was not copied during
the VM scaffold because this VM's sandbox currently denies file-content
writes from shell/toolchain processes (see the main README, "What blocked
the in-VM build"). On any normal machine the `cp` above just works.
