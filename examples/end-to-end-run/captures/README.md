# 실행 캡처

이 폴더의 `.out` 파일은 문서 예시가 아니라 **실제 실행 stdout**이고, 같은 이름의 `.exit`
파일은 그 실행의 종료 코드다. 파일 mtime이 캡처 시각이다.

| 파일 | 만든 명령 | exit |
|---|---|---|
| `reach-doctor.out` / `.exit` | `bash skill/scripts/reach-doctor.sh` | 0 |
| `verdict-gate.out` / `.exit` | `bash skill/scripts/verdict-gate.sh examples/end-to-end-run/.assay/run1` | 0 |

재생성:

```bash
bash skill/scripts/reach-doctor.sh > examples/end-to-end-run/captures/reach-doctor.out 2>&1
echo $? > examples/end-to-end-run/captures/reach-doctor.exit

bash skill/scripts/verdict-gate.sh examples/end-to-end-run/.assay/run1 \
  > examples/end-to-end-run/captures/verdict-gate.out 2>&1
echo $? > examples/end-to-end-run/captures/verdict-gate.exit
```

`reach-doctor.sh`는 네트워크 probe를 돌기 때문에 출력의 `ok`/`missing`/`warn`은 실행 환경에
따라 달라진다. 이 캡처는 `L1 insane-search`가 없는 머신에서 나온 것이다.
