import { useCallback, useEffect, useRef, useState } from 'react'
import type { TranslationMessage } from '../../i18n/index.js'
import { canUseCloudAsr, transcribe } from '../../services/api/speech.js'
import {
  createHarmonySpeechId,
  DeepSeekMigration,
  getHarmonySpeechBridge,
  isNativeAndroid,
  isNativeIos,
  type HarmonyAsrError,
  type HarmonyAsrEvent,
} from '../../services/nativeBridge.js'
import { MAX_SECONDS, startRecording, type Recording } from '../../services/speech/recorder.js'
import { getActiveSecret, useSettings } from '../../services/settings.js'
import { showToast } from '../base/toastState.js'

export type VoiceInputStatus = 'idle' | 'recording' | 'transcribing'

/**
 * 录音依赖 getUserMedia 或原生语音识别，只在安全上下文可用（HTTPS、localhost、file://）。
 * 普通 HTTP 页面上直接禁用入口，避免点击后必然失败。
 */
const AVAILABLE = typeof window === 'undefined' || window.isSecureContext
const HARMONY_ASR_EVENT = 'nuwa:harmony-asr'
// 系统短语音最多录制 60 秒。预留时间接收结束事件，并在事件丢失时收尾。
const HARMONY_ASR_COMPLETION_TIMEOUT = 65_000

/** 原生壳（Android/iOS）走设备语音识别：speechEngine=native 强制原生；无 API Key 时云端不可用回落原生 */
const useNativeAsr = (): boolean => {
  if (!isNativeAndroid() && !isNativeIos()) {
    return false
  }
  const engine = useSettings.getState().speechEngine
  return engine === 'native' || !canUseCloudAsr()
}

const describeRecordingError = (error: unknown): TranslationMessage => {
  if (error instanceof DOMException) {
    if (error.name === 'NotAllowedError' || error.name === 'SecurityError') {
      return {
        key:
          isNativeAndroid() || isNativeIos()
            ? 'voiceInputPermissionDeniedAndroid'
            : 'voiceInputPermissionDenied',
      }
    }
    if (error.name === 'NotFoundError') {
      return { key: 'voiceInputNoDevice' }
    }
  }
  if (error instanceof Error && error.message.includes('PERMISSION_DENIED')) {
    return {
      key:
        isNativeAndroid() || isNativeIos()
          ? 'voiceInputPermissionDeniedAndroid'
          : 'voiceInputPermissionDenied',
    }
  }
  return { key: 'voiceInputFailed' }
}

const describeHarmonyAsrError = (code?: HarmonyAsrError): TranslationMessage => {
  if (code === 'permission-denied') {
    return { key: 'voiceInputPermissionDeniedAndroid' }
  }
  if (code === 'unavailable') {
    return { key: 'voiceInputSystemUnavailable' }
  }
  return { key: 'voiceInputFailed' }
}

/**
 * 语音输入（oneshot）：点击开始录音，再次点击结束并转写，结果交给 onText 填入输入框。
 * 转写中再次点击取消。录满 120 秒自动结束。
 */
export const useVoiceInput = (onText: (text: string) => void) => {
  const [status, setStatus] = useState<VoiceInputStatus>('idle')
  /** 本次录音已录秒数，只在录音中递增 */
  const [seconds, setSeconds] = useState(0)
  const recordingRef = useRef<Recording | null>(null)
  const harmonyRecognitionRef = useRef<{ stop: () => void; cancel: () => void } | null>(null)
  const nativeActiveRef = useRef(false)
  const cleanupNativeRef = useRef<(() => void) | null>(null)
  const levelRef = useRef(0)
  const controllerRef = useRef<AbortController | null>(null)
  const operationRef = useRef(0)
  const onTextRef = useRef(onText)
  onTextRef.current = onText

  const cancelOperation = useCallback(() => {
    operationRef.current++
    harmonyRecognitionRef.current?.cancel()
    cleanupNativeRef.current?.()
    cleanupNativeRef.current = null
    levelRef.current = 0
    if (nativeActiveRef.current) {
      nativeActiveRef.current = false
      void DeepSeekMigration.cancelSpeechRecognition().catch(() => {})
    }
    recordingRef.current?.cancel()
    recordingRef.current = null
    controllerRef.current?.abort()
    controllerRef.current = null
  }, [])

  const cancel = useCallback(() => {
    cancelOperation()
    setStatus('idle')
  }, [cancelOperation])

  const finish = useCallback(async () => {
    if (harmonyRecognitionRef.current) {
      harmonyRecognitionRef.current.stop()
      return
    }
    if (nativeActiveRef.current) {
      const operation = operationRef.current
      cleanupNativeRef.current?.()
      cleanupNativeRef.current = null
      nativeActiveRef.current = false
      levelRef.current = 0
      setStatus('transcribing')
      try {
        const result = await DeepSeekMigration.stopSpeechRecognition()
        if (operationRef.current !== operation) {
          return
        }
        if (result.text.trim()) {
          onTextRef.current(result.text.trim())
        } else {
          showToast({ key: 'voiceInputEmpty' })
        }
      } catch {
        if (operationRef.current === operation) {
          showToast({ key: 'voiceInputFailed' })
        }
      } finally {
        if (operationRef.current === operation) {
          setStatus('idle')
        }
      }
      return
    }

    const recording = recordingRef.current
    if (!recording) {
      // 仍在等待麦克风授权时也允许取消；迟到的录音对象会立即释放。
      cancel()
      return
    }
    const operation = operationRef.current
    recordingRef.current = null
    let controller: AbortController | null = null
    try {
      let audio: Blob | null
      try {
        audio = await recording.stop()
      } finally {
        recording.cancel()
      }
      if (operationRef.current !== operation || !audio) {
        return
      }
      controller = new AbortController()
      controllerRef.current = controller
      setStatus('transcribing')
      const text = await transcribe(getActiveSecret(), audio, controller.signal)
      if (controller.signal.aborted || operationRef.current !== operation) {
        return
      }
      if (text.trim()) {
        onTextRef.current(text.trim())
      } else {
        showToast({ key: 'voiceInputEmpty' })
      }
    } catch {
      if (operationRef.current === operation && !controller?.signal.aborted) {
        showToast({ key: 'voiceInputFailed' })
      }
    } finally {
      if (operationRef.current === operation) {
        controllerRef.current = null
        setStatus('idle')
      }
    }
  }, [cancel])

  const toggle = useCallback(async () => {
    const harmonyBridge = getHarmonySpeechBridge()
    if (!harmonyBridge && !AVAILABLE) {
      return
    }
    if (status === 'recording') {
      await finish()
      return
    }
    if (status === 'transcribing') {
      cancel()
      return
    }
    const operation = ++operationRef.current
    setStatus('recording')
    levelRef.current = 0

    if (harmonyBridge) {
      if (
        !harmonyBridge.startSpeechRecognition ||
        !harmonyBridge.stopSpeechRecognition ||
        !harmonyBridge.cancelSpeechRecognition
      ) {
        setStatus('idle')
        showToast(describeHarmonyAsrError('unavailable'))
        return
      }

      const id = createHarmonySpeechId()
      let started = false
      let stopping = false
      let timer: number | undefined
      const close = () => {
        window.clearTimeout(timer)
        window.removeEventListener(HARMONY_ASR_EVENT, onState)
        harmonyRecognitionRef.current = null
      }
      const cancelHarmonyRecognition = () => {
        close()
        try {
          harmonyBridge.cancelSpeechRecognition?.(id)
        } catch {
          // 页面关闭后桥接可能已销毁。
        }
      }
      const fail = () => {
        cancelHarmonyRecognition()
        setStatus('idle')
        showToast(describeHarmonyAsrError())
      }
      const stop = () => {
        if (!started) {
          cancelHarmonyRecognition()
          setStatus('idle')
          return
        }
        if (stopping) {
          return
        }
        stopping = true
        setStatus('transcribing')
        window.clearTimeout(timer)
        timer = window.setTimeout(fail, 8_000)
        try {
          harmonyBridge.stopSpeechRecognition?.(id)
        } catch {
          fail()
        }
      }
      const onState = (event: Event) => {
        const detail = (event as CustomEvent<HarmonyAsrEvent>).detail
        if (detail?.id !== id || operationRef.current !== operation) {
          return
        }
        if (detail.state === 'started' && !started) {
          started = true
          window.clearTimeout(timer)
          timer = window.setTimeout(stop, HARMONY_ASR_COMPLETION_TIMEOUT)
        } else if (detail.state === 'done' || detail.state === 'error') {
          close()
          setStatus('idle')
          if (detail.state === 'error') {
            showToast(describeHarmonyAsrError(detail.code))
            return
          }
          const text = detail.text?.trim()
          if (text) {
            onTextRef.current(text)
          } else {
            showToast({ key: 'voiceInputEmpty' })
          }
        }
      }
      harmonyRecognitionRef.current = { stop, cancel: cancelHarmonyRecognition }
      window.addEventListener(HARMONY_ASR_EVENT, onState)
      timer = window.setTimeout(fail, HARMONY_ASR_COMPLETION_TIMEOUT)
      try {
        harmonyBridge.startSpeechRecognition(id, useSettings.getState().locale)
      } catch {
        fail()
      }
      return
    }

    if (useNativeAsr()) {
      try {
        const permission = await DeepSeekMigration.ensureMicrophonePermission()
        if (operationRef.current !== operation) {
          return
        }
        if (!permission.granted) {
          throw new DOMException('Microphone permission denied', 'NotAllowedError')
        }

        const onRms = (event: Event) => {
          const detail = (event as CustomEvent<unknown>).detail
          if (typeof detail === 'number' && Number.isFinite(detail)) {
            levelRef.current = detail
          }
        }
        const onNativeError = (event: Event) => {
          if (operationRef.current !== operation) {
            return
          }
          cleanupNativeRef.current?.()
          cleanupNativeRef.current = null
          nativeActiveRef.current = false
          levelRef.current = 0
          setStatus('idle')
          const detail = (event as CustomEvent<unknown>).detail
          showToast({
            key:
              detail === 'PERMISSION_DENIED'
                ? 'voiceInputPermissionDeniedAndroid'
                : 'voiceInputFailed',
          })
        }
        const limitTimer = window.setTimeout(() => {
          if (operationRef.current === operation && nativeActiveRef.current) {
            showToast({ key: 'voiceInputLimitReached' })
            void finish()
          }
        }, MAX_SECONDS * 1000)

        window.addEventListener('dsapp:speech-rms', onRms)
        window.addEventListener('dsapp:speech-error', onNativeError)
        cleanupNativeRef.current = () => {
          window.clearTimeout(limitTimer)
          window.removeEventListener('dsapp:speech-rms', onRms)
          window.removeEventListener('dsapp:speech-error', onNativeError)
        }

        await DeepSeekMigration.startSpeechRecognition({ locale: useSettings.getState().locale })
        if (operationRef.current !== operation) {
          cleanupNativeRef.current?.()
          cleanupNativeRef.current = null
          void DeepSeekMigration.cancelSpeechRecognition().catch(() => {})
          return
        }
        nativeActiveRef.current = true
      } catch (error) {
        cleanupNativeRef.current?.()
        cleanupNativeRef.current = null
        nativeActiveRef.current = false
        levelRef.current = 0
        if (operationRef.current === operation) {
          setStatus('idle')
          showToast(describeRecordingError(error))
        }
      }
      return
    }

    try {
      const recording = await startRecording(() => {
        if (operationRef.current === operation) {
          showToast({ key: 'voiceInputLimitReached' })
          void finish()
        }
      })
      if (operationRef.current !== operation) {
        recording.cancel()
        return
      }
      recordingRef.current = recording
    } catch (error) {
      if (operationRef.current === operation) {
        setStatus('idle')
        showToast(describeRecordingError(error))
      }
    }
  }, [status, finish, cancel])

  useEffect(() => {
    if (status !== 'recording') {
      return
    }
    const startedAt = Date.now()
    setSeconds(0)
    // 半秒刷新一次，让显示的秒数与实际录音时长保持一致
    const timer = setInterval(() => {
      setSeconds(Math.floor((Date.now() - startedAt) / 1000))
    }, 500)
    return () => clearInterval(timer)
  }, [status])

  useEffect(() => cancelOperation, [cancelOperation])

  /** 当前录音的频谱分析节点，未录音时为 null */
  const getAnalyser = useCallback(() => recordingRef.current?.analyser ?? null, [])
  /** 原生安卓语音识别时的归一化音量信号，供频谱柱渲染 */
  const getLevel = useCallback(() => levelRef.current, [])

  return {
    status,
    seconds,
    getAnalyser,
    getLevel,
    toggle,
    cancel,
    available: AVAILABLE || Boolean(getHarmonySpeechBridge()),
  }
}
