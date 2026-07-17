package main

import (
	"crypto/hmac"
	"crypto/sha256"
	"encoding/hex"
	"encoding/xml"
	"errors"
	"flag"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"strings"
	"time"
)

const emptyPayloadSHA256 = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"

type config struct {
	Endpoint  string
	Bucket    string
	Object    string
	Output    string
	AccessKey string
	SecretKey string
	Region    string
}

type regionError struct {
	Region string
}

func (e *regionError) Error() string {
	return "S3 endpoint requires signing region " + e.Region
}

func main() {
	cfg := config{}
	flag.StringVar(&cfg.Endpoint, "endpoint", "", "S3-compatible endpoint URL")
	flag.StringVar(&cfg.Bucket, "bucket", "", "bucket name")
	flag.StringVar(&cfg.Object, "object", "", "object key")
	flag.StringVar(&cfg.Output, "output", "", "destination file")
	flag.StringVar(&cfg.AccessKey, "access-key", "", "S3 access key")
	flag.StringVar(&cfg.SecretKey, "secret-key", "", "S3 secret key")
	flag.StringVar(&cfg.Region, "region", "us-east-1", "S3 signing region")
	flag.Parse()

	if err := download(cfg); err != nil {
		fmt.Fprintf(os.Stderr, "s3-fetch: %v\n", err)
		os.Exit(1)
	}
}

func download(cfg config) error {
	if cfg.Endpoint == "" || cfg.Bucket == "" || cfg.Object == "" || cfg.Output == "" || cfg.AccessKey == "" || cfg.SecretKey == "" {
		return errors.New("endpoint, bucket, object, output, access-key, and secret-key are required")
	}
	u, err := objectURL(cfg.Endpoint, cfg.Bucket, cfg.Object)
	if err != nil {
		return err
	}

	client := &http.Client{Timeout: 20 * time.Minute}
	var lastErr error
	for attempt := 1; attempt <= 3; attempt++ {
		if err := fetchOnce(client, u, cfg, time.Now().UTC()); err == nil {
			return nil
		} else {
			lastErr = err
			var wrongRegion *regionError
			if errors.As(err, &wrongRegion) {
				cfg.Region = wrongRegion.Region
				continue
			}
		}
		if attempt < 3 {
			time.Sleep(time.Duration(attempt*2) * time.Second)
		}
	}
	return lastErr
}

func objectURL(endpoint, bucket, object string) (*url.URL, error) {
	u, err := url.Parse(strings.TrimRight(endpoint, "/"))
	if err != nil {
		return nil, fmt.Errorf("parse endpoint: %w", err)
	}
	if u.Scheme != "http" && u.Scheme != "https" {
		return nil, errors.New("endpoint must use http or https")
	}
	if u.Host == "" {
		return nil, errors.New("endpoint host is empty")
	}
	u.RawQuery = ""
	u.Fragment = ""
	u.Path = strings.TrimRight(u.Path, "/") + "/" + bucket + "/" + strings.TrimLeft(object, "/")
	return u, nil
}

func fetchOnce(client *http.Client, u *url.URL, cfg config, now time.Time) error {
	req, err := http.NewRequest(http.MethodGet, u.String(), nil)
	if err != nil {
		return err
	}
	sign(req, cfg.AccessKey, cfg.SecretKey, cfg.Region, now)

	resp, err := client.Do(req)
	if err != nil {
		return fmt.Errorf("download object: %w", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		message, _ := io.ReadAll(io.LimitReader(resp.Body, 4096))
		var s3err struct {
			Code   string `xml:"Code"`
			Region string `xml:"Region"`
		}
		if xml.Unmarshal(message, &s3err) == nil && s3err.Code == "AuthorizationHeaderMalformed" && s3err.Region != "" {
			return &regionError{Region: s3err.Region}
		}
		return fmt.Errorf("download object: HTTP %d: %s", resp.StatusCode, strings.TrimSpace(string(message)))
	}

	if err := os.MkdirAll(filepath.Dir(cfg.Output), 0o755); err != nil {
		return err
	}
	tmp, err := os.CreateTemp(filepath.Dir(cfg.Output), ".s3-fetch-*")
	if err != nil {
		return err
	}
	tmpName := tmp.Name()
	defer os.Remove(tmpName)
	if _, err := io.Copy(tmp, resp.Body); err != nil {
		tmp.Close()
		return fmt.Errorf("write object: %w", err)
	}
	if err := tmp.Close(); err != nil {
		return err
	}
	if err := os.Chmod(tmpName, 0o600); err != nil {
		return err
	}
	if err := os.Rename(tmpName, cfg.Output); err != nil {
		return err
	}
	return nil
}

func sign(req *http.Request, accessKey, secretKey, region string, now time.Time) {
	amzDate := now.Format("20060102T150405Z")
	date := now.Format("20060102")
	canonicalHeaders := "host:" + req.URL.Host + "\n" +
		"x-amz-content-sha256:" + emptyPayloadSHA256 + "\n" +
		"x-amz-date:" + amzDate + "\n"
	signedHeaders := "host;x-amz-content-sha256;x-amz-date"
	canonicalRequest := strings.Join([]string{
		req.Method,
		req.URL.EscapedPath(),
		req.URL.Query().Encode(),
		canonicalHeaders,
		signedHeaders,
		emptyPayloadSHA256,
	}, "\n")
	scope := date + "/" + region + "/s3/aws4_request"
	stringToSign := "AWS4-HMAC-SHA256\n" + amzDate + "\n" + scope + "\n" + sha256Hex(canonicalRequest)
	dateKey := hmacSHA256([]byte("AWS4"+secretKey), date)
	regionKey := hmacSHA256(dateKey, region)
	serviceKey := hmacSHA256(regionKey, "s3")
	signingKey := hmacSHA256(serviceKey, "aws4_request")
	signature := hex.EncodeToString(hmacSHA256(signingKey, stringToSign))

	req.Header.Set("X-Amz-Date", amzDate)
	req.Header.Set("X-Amz-Content-Sha256", emptyPayloadSHA256)
	req.Header.Set("Authorization", "AWS4-HMAC-SHA256 Credential="+accessKey+"/"+scope+", SignedHeaders="+signedHeaders+", Signature="+signature)
}

func sha256Hex(value string) string {
	sum := sha256.Sum256([]byte(value))
	return hex.EncodeToString(sum[:])
}

func hmacSHA256(key []byte, value string) []byte {
	h := hmac.New(sha256.New, key)
	_, _ = h.Write([]byte(value))
	return h.Sum(nil)
}
