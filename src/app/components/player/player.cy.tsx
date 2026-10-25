import { usePlayerStore } from '@/store/player.store'
import { LoopState } from '@/types/playerContext'
import { ISong } from '@/types/responses/song'
import { perceptualToGain } from '@/utils/volume'
import { Player } from './player'

// The HTTP client rejects bodies that are not a Subsonic response envelope.
const subsonicOk = { 'subsonic-response': { status: 'ok', version: '1.16.1' } }

// The mobile control bar reuses the play/pause test ids and is only hidden
// by CSS, so pick the one that is actually shown.
function getVisibleByTestId(testId: string) {
  return cy.getByTestId(testId).filter(':visible')
}

function shouldHaveVolume(percent: number) {
  cy.getByTestId<HTMLAudioElement>('player-song-audio').should(($audio) => {
    const { volume } = usePlayerStore.getState().playerState

    expect(volume, 'Slider volume').to.equal(percent)
    // The element gets the perceptual gain curve, not the raw percentage.
    expect($audio[0].volume, 'Audio element volume').to.be.closeTo(
      perceptualToGain(percent),
      0.0001,
    )
  })
}

function shouldHaveLoopState(expected: LoopState) {
  cy.then(() => {
    const { loopState } = usePlayerStore.getState().playerState

    expect(loopState, 'Loop state').to.equal(expected)
  })
}

// Make the element report a duration and let the player pick it up, no matter
// whether the fixture's own metadata has finished loading yet.
function setAudioDuration(audio: HTMLAudioElement, duration: number) {
  Object.defineProperty(audio, 'duration', {
    writable: true,
    value: duration,
  })
  audio.dispatchEvent(new Event('durationchange'))
}

describe('Player Component', () => {
  beforeEach(() => {
    cy.mockCoverArt()
    cy.mockSongStream()
    // Starting a song reports it as now playing.
    cy.intercept('/rest/scrobble**', { body: subsonicOk })
  })

  afterEach(() => {
    const { actions } = usePlayerStore.getState()

    actions.clearPlayerState()
    actions.setVolume(100)
  })

  it('should mount the player and interact with it', () => {
    cy.fixture('songs/random').then((songs: ISong[]) => {
      usePlayerStore.getState().actions.setSongList(songs, 0)
      usePlayerStore.getState().actions.setPlayingState(false)

      cy.mount(<Player />)

      getVisibleByTestId('player-button-play').as('playButton')
      cy.get('@playButton').should('be.visible')

      cy.getByTestId<HTMLAudioElement>('player-song-audio').then(($audio) => {
        const $el = $audio[0]

        cy.stub($el, 'load').as('loadStub')
        cy.stub($el, 'play').as('playStub')
        cy.stub($el, 'pause').as('pauseStub')

        $el.removeAttribute('autoplay')
      })

      cy.getByTestId('player-current-time').should('have.text', '00:00')
      cy.getByTestId('player-duration-time').should('have.text', '03:27')

      cy.get('@playButton').click()
      cy.get('@playStub').should('have.been.called')

      getVisibleByTestId('player-button-pause').as('pauseButton')
      cy.get('@pauseButton').should('be.visible')

      cy.get('@pauseButton').click()
      cy.get('@pauseStub').should('have.been.called')

      cy.get('@playButton').should('be.visible')

      cy.getByTestId('player-button-shuffle')
        .should('be.visible')
        .and('not.have.attr', 'disabled')

      cy.getByTestId('player-button-prev')
        .should('be.visible')
        .and('not.have.attr', 'disabled')

      cy.getByTestId('player-button-next')
        .should('be.visible')
        .and('not.have.attr', 'disabled')

      cy.getByTestId('player-button-loop')
        .should('be.visible')
        .and('not.have.attr', 'disabled')
    })
  })

  it('should mount the player with a single song', () => {
    cy.fixture('songs/random').then((songs: ISong[]) => {
      usePlayerStore.getState().actions.setSongList([songs[1]], 0)
      usePlayerStore.getState().actions.setPlayingState(false)

      cy.mount(<Player />)

      cy.getByTestId('player-button-shuffle')
        .should('be.visible')
        .and('have.attr', 'disabled', 'disabled')

      cy.getByTestId('player-button-prev')
        .should('be.visible')
        .and('not.have.attr', 'disabled')

      cy.getByTestId('player-button-next')
        .should('be.visible')
        .and('have.attr', 'disabled', 'disabled')

      cy.getByTestId('player-button-loop')
        .should('be.visible')
        .and('not.have.attr', 'disabled')
    })
  })

  it('should mount the player with the last song on a list', () => {
    cy.fixture('songs/random').then((songs: ISong[]) => {
      usePlayerStore.getState().actions.setSongList(songs, songs.length - 1)
      usePlayerStore.getState().actions.setPlayingState(false)

      cy.mount(<Player />)

      cy.getByTestId('player-button-shuffle')
        .should('be.visible')
        .and('have.attr', 'disabled', 'disabled')

      cy.getByTestId('player-button-prev')
        .should('be.visible')
        .and('not.have.attr', 'disabled')

      cy.getByTestId('player-button-next')
        .should('be.visible')
        .and('have.attr', 'disabled', 'disabled')

      cy.getByTestId('player-button-loop')
        .should('be.visible')
        .and('not.have.attr', 'disabled')
    })
  })

  it('should mount the player and change the volume', () => {
    cy.fixture('songs/random').then((songs: ISong[]) => {
      usePlayerStore.getState().actions.setSongList([songs[1]], 0)
      usePlayerStore.getState().actions.setPlayingState(false)

      cy.mount(<Player />)

      shouldHaveVolume(100)

      cy.getByTestId('player-volume-slider').click()

      shouldHaveVolume(50)

      cy.getByTestId('player-volume-slider').click(20, 4)

      shouldHaveVolume(16)
    })
  })

  it('should mount the player and toggle the shuffle button', () => {
    cy.fixture('songs/random').then((songs: ISong[]) => {
      usePlayerStore.getState().actions.setSongList(songs, 0)
      usePlayerStore.getState().actions.setPlayingState(false)

      cy.mount(<Player />)

      cy.getByTestId('player-button-shuffle')
        .as('shuffleButton')
        .should('be.visible')
        .and('not.have.class', 'player-button-active')

      cy.get('@shuffleButton').click()

      cy.get('@shuffleButton')
        .should('have.class', 'player-button-active')
        .then(() => {
          const songListAfterShuffle =
            usePlayerStore.getState().songlist.contextQueue.songs

          cy.wrap(songListAfterShuffle).should('not.deep.equal', songs)
          cy.wrap(songListAfterShuffle).should('have.members', songs)
        })
    })
  })

  it('should mount the player and toggle the loop button', () => {
    cy.fixture('songs/random').then((songs: ISong[]) => {
      usePlayerStore.getState().actions.setSongList(songs, 0)
      usePlayerStore.getState().actions.setPlayingState(false)

      cy.mount(<Player />)

      cy.getByTestId('player-button-loop')
        .as('loopButton')
        .should('be.visible')
        .and('not.have.class', 'player-button-active')

      shouldHaveLoopState(LoopState.Off)

      cy.get('@loopButton').click()

      cy.get('@loopButton').should('have.class', 'player-button-active')

      shouldHaveLoopState(LoopState.All)

      cy.get('@loopButton').click()

      cy.get('@loopButton').should('have.class', 'player-button-active')

      shouldHaveLoopState(LoopState.One)

      // Repeat one is not the audio element's own `loop`: the player restarts
      // the current song when it ends instead of moving on to the next one.
      cy.getByTestId<HTMLAudioElement>('player-song-audio').then(($audio) => {
        const audio = $audio[0]

        cy.stub(audio, 'play').as('playStub').resolves()
        audio.dispatchEvent(new Event('ended'))
      })

      cy.get('@playStub').should('have.been.called')

      cy.then(() => {
        const { currentSong } = usePlayerStore.getState().songlist

        expect(currentSong?.id, 'Current song').to.equal(songs[0].id)
      })

      cy.get('@loopButton').click()

      cy.get('@loopButton').should('not.have.class', 'player-button-active')

      shouldHaveLoopState(LoopState.Off)
    })
  })

  it('should mount the player and change the progress slider', () => {
    // Only the played-song submission, not the now playing report.
    cy.intercept(
      { pathname: '/rest/scrobble', query: { submission: 'true' } },
      { body: subsonicOk },
    ).as('scrobbleRequest')

    cy.fixture('songs/random').then((songs: ISong[]) => {
      usePlayerStore.getState().actions.setSongList(songs, 0)
      usePlayerStore.getState().actions.setPlayingState(false)

      cy.mount(<Player />)

      cy.getByTestId('player-current-time').should('have.text', '00:00')
      cy.getByTestId('player-duration-time').should('have.text', '03:27')

      // Move the playhead past half of the 03:27 fixture. The mocked stream
      // has no range support, so the element itself cannot seek.
      cy.getByTestId<HTMLAudioElement>('player-song-audio').then(($audio) => {
        const audio = $audio[0]

        cy.stub(audio, 'play').resolves()
        Object.defineProperty(audio, 'currentTime', {
          configurable: true,
          get: () => 105,
          set: () => {},
        })
        audio.dispatchEvent(new Event('timeupdate'))
      })

      cy.getByTestId('player-current-time').should('have.text', '01:45')

      // A scrobble is only submitted while playing.
      cy.then(() => {
        usePlayerStore.getState().actions.setPlayingState(true)
      })

      cy.wait('@scrobbleRequest').then((interception) => {
        expect(interception.request.method, 'Request method').to.equal('GET')
        expect(interception.response?.statusCode, 'Status code').to.equal(200)
      })
    })
  })

  it('should mount the player and like the song', () => {
    cy.intercept('/rest/star**', { body: subsonicOk }).as('starRequest')

    cy.fixture('songs/random').then((songs: ISong[]) => {
      usePlayerStore.getState().actions.setSongList(songs, 0)
      usePlayerStore.getState().actions.setPlayingState(false)

      cy.mount(<Player />)

      cy.getByTestId('player-like-icon')
        .should('be.visible')
        .and('not.have.class', 'text-red-500')
        .and('not.have.class', 'fill-red-500')

      cy.getByTestId('player-like-button').click()

      cy.wait('@starRequest').then((interception) => {
        expect(interception.request.method, 'Request method').to.equal('GET')
        expect(interception.response?.statusCode, 'Status code').to.equal(200)
      })

      cy.getByTestId('player-like-icon')
        .should('be.visible')
        .and('have.class', 'text-red-500')
        .and('have.class', 'fill-red-500')
    })
  })

  it('should use audio element duration instead of metadata for local playback', () => {
    cy.fixture('songs/random').then((songs: ISong[]) => {
      const song = songs[0]
      usePlayerStore.getState().actions.setSongList([song], 0)
      usePlayerStore.getState().actions.setPlayingState(false)

      cy.mount(<Player />)

      cy.getByTestId<HTMLAudioElement>('player-song-audio').then(($audio) => {
        const audio = $audio[0]

        cy.stub(audio, 'load').as('loadStub')
        cy.stub(audio, 'play').as('playStub')
        audio.removeAttribute('autoplay')

        setAudioDuration(audio, 300.4)
      })

      cy.getByTestId('player-current-time').should('have.text', '00:00')

      cy.getByTestId<HTMLAudioElement>('player-song-audio').should(($audio) => {
        const audio = $audio[0]
        const duration = usePlayerStore.getState().playerState.currentDuration

        expect(duration).to.equal(Math.round(audio.duration))
      })
    })
  })

  it('should not prematurely switch songs when metadata duration is shorter than actual duration', () => {
    cy.fixture('songs/random').then((songs: ISong[]) => {
      const song = { ...songs[0], duration: 180 }
      usePlayerStore.getState().actions.setSongList([song], 0)
      usePlayerStore.getState().actions.setPlayingState(false)

      cy.mount(<Player />)

      cy.getByTestId<HTMLAudioElement>('player-song-audio').then(($audio) => {
        const audio = $audio[0]

        cy.stub(audio, 'load').as('loadStub')
        cy.stub(audio, 'play').as('playStub')
        audio.removeAttribute('autoplay')

        setAudioDuration(audio, 300)
      })

      cy.getByTestId('player-duration-time').should('have.text', '05:00')
    })
  })

  it('should handle invalid audio duration gracefully', () => {
    cy.fixture('songs/random').then((songs: ISong[]) => {
      const song = songs[0]
      usePlayerStore.getState().actions.setSongList([song], 0)
      usePlayerStore.getState().actions.setPlayingState(false)
      usePlayerStore.getState().actions.setCurrentDuration(0)

      cy.mount(<Player />)

      cy.getByTestId<HTMLAudioElement>('player-song-audio').then(($audio) => {
        const audio = $audio[0]

        Object.defineProperty(audio, 'duration', {
          writable: true,
          value: NaN,
        })

        cy.stub(audio, 'load').as('loadStub')
        cy.stub(audio, 'play').as('playStub')
        audio.removeAttribute('autoplay')
      })

      cy.getByTestId<HTMLAudioElement>('player-song-audio').then(() => {
        const duration = usePlayerStore.getState().playerState.currentDuration
        expect(duration).to.equal(0)
      })
    })
  })
})
